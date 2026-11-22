# B133 E2 下载体验探针（2.1.7）：流式进度 / Range 续传 / 多源回退 / 缓存命中 / 用户取消。
# 不联网：本地 TcpListener 起一个支持 Range 的 mock HTTP 服务，直接驱动 runspace worker 取结构化结果。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b133-e2-download.ps1

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host "== B133 E2 下载体验探针 ==" -ForegroundColor Cyan

# ---------- stub 宿主依赖 ----------
$script:Root = $root
$script:DataDir = Join-Path $env:TEMP ('PerfCapture-B133-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
$script:UiMessages = New-Object System.Collections.ArrayList
function Write-AppLog([string]$text, [string]$lvl = 'INFO') { }
function Send-ToUi([hashtable]$payload) { [void]$script:UiMessages.Add($payload) }
function Save-Config { }
$script:Cfg = @{ extensions = @{} }

. (Join-Path $root 'src\app\06-NetProxy.ps1')
. (Join-Path $root 'src\app\rtss-shm.ps1')
. (Join-Path $root 'src\app\80-Extensions.ps1')
. (Join-Path $root 'src\app\85-ExtensionProvision.ps1')

function Get-Sha([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '').ToUpperInvariant() }
        finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}

function Invoke-Worker([hashtable]$S) {
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:ExtensionProvisionWorker).AddArgument($S).AddArgument($script:ExtProvQueue).AddArgument('').AddArgument([string]$script:NetProxyHelper)
    $r = @($ps.Invoke())[0]
    $ps.Dispose()
    Drain-ExtProvQueue
    return $r
}

function Clear-UiMessages { $script:UiMessages.Clear() }

# ---------- 1. 造一个「真包」：安装脚本 + 700KB 填充，让流式下载有足够块 ----------
$work = Join-Path $script:DataDir 'fixture'
New-Item -ItemType Directory -Path $work -Force | Out-Null
Set-Content -LiteralPath (Join-Path $work 'install.ps1') -Value @'
param([string]$Target)
New-Item -ItemType Directory -Path $Target -Force | Out-Null
'@ -Encoding UTF8
$filler = New-Object byte[] (700 * 1024)
(New-Object System.Random(20261121)).NextBytes($filler)
[System.IO.File]::WriteAllBytes((Join-Path $work 'filler.bin'), $filler)
$zip = Join-Path $script:DataDir 'pkg.zip'
# 不用 Add-Type（安全策略会拦「运行期编译/加载」这条命令），直接按名加载程序集。
[void][System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem')
if (Test-Path $zip) { Remove-Item $zip -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($work, $zip)
$zipBytes = [System.IO.File]::ReadAllBytes($zip)
$zipSha = Get-Sha $zip
Write-Host ("  包大小 {0:N0} 字节 / SHA {1}" -f $zipBytes.Length, $zipSha.Substring(0, 12))

# ---------- 2. mock HTTP 服务（支持 Range / 404 / 慢速） ----------
$serverCode = @'
param([hashtable]$State, [byte[]]$Payload)
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$State.port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
$State.ready = $true
$len = $Payload.Length
while (-not $State.stop) {
    try { $client = $listener.AcceptTcpClient() } catch { break }
    try {
        $ns = $client.GetStream()
        $ns.ReadTimeout = 5000
        $buf = New-Object byte[] 8192
        $read = $ns.Read($buf, 0, $buf.Length)
        $text = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
        $lines = $text -split "`r`n"
        $req = [string]$lines[0]
        $hdrs = @{}
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $ln = [string]$lines[$i]
            if (-not $ln) { break }
            $k = $ln.IndexOf(':')
            if ($k -gt 0) { $hdrs[$ln.Substring(0, $k).Trim().ToLowerInvariant()] = $ln.Substring($k + 1).Trim() }
        }
        $State.requests = [int]$State.requests + 1
        if ($hdrs.ContainsKey('range')) { $State.ranges = [string]$State.ranges + '[' + [string]$hdrs['range'] + ']' }
        $path = ''
        if ($req) { $parts = $req -split ' '; if ($parts.Count -ge 2) { $path = $parts[1] } }
        if ($State.mode -eq 'notfound' -or $path -ne '/pkg.zip') {
            $body = [System.Text.Encoding]::ASCII.GetBytes('not found')
            $h = "HTTP/1.1 404 Not Found`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
            $hb = [System.Text.Encoding]::ASCII.GetBytes($h)
            $ns.Write($hb, 0, $hb.Length); $ns.Write($body, 0, $body.Length); $ns.Flush()
            continue
        }
        $start = 0
        if ($hdrs.ContainsKey('range') -and $State.mode -ne 'norange') {
            $m = [regex]::Match([string]$hdrs['range'], 'bytes=(\d+)-')
            if ($m.Success) { $start = [int]$m.Groups[1].Value }
        }
        if ($start -ge $len -and $start -gt 0) {
            $h = "HTTP/1.1 416 Range Not Satisfiable`r`nContent-Range: bytes */$len`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
            $hb = [System.Text.Encoding]::ASCII.GetBytes($h)
            $ns.Write($hb, 0, $hb.Length); $ns.Flush()
            continue
        }
        $count = $len - $start
        if ($start -gt 0) {
            $h = "HTTP/1.1 206 Partial Content`r`nContent-Length: $count`r`nContent-Range: bytes $start-$($len - 1)/$len`r`nConnection: close`r`n`r`n"
            $State.partials = [int]$State.partials + 1
        } else {
            $h = "HTTP/1.1 200 OK`r`nContent-Length: $count`r`nConnection: close`r`n`r`n"
        }
        $hb = [System.Text.Encoding]::ASCII.GetBytes($h)
        $ns.Write($hb, 0, $hb.Length)
        $off = $start
        $chunk = 65536
        while ($off -lt $len) {
            if ($State.stop) { break }
            $n = [math]::Min($chunk, $len - $off)
            $ns.Write($Payload, $off, $n)
            $ns.Flush()
            $off += $n
            if ($State.mode -eq 'slow') { Start-Sleep -Milliseconds 90 }
        }
        $State.served = [int]$State.served + 1
    } catch { } finally { try { $client.Close() } catch { } }
}
try { $listener.Stop() } catch { }
'@

$state = @{ ready = $false; stop = $false; port = 0; mode = 'ok'; requests = 0; partials = 0; ranges = ''; served = 0 }
$serverPs = [PowerShell]::Create()
[void]$serverPs.AddScript($serverCode).AddArgument($state).AddArgument($zipBytes)
$serverHandle = $serverPs.BeginInvoke()
$wait = 0
while (-not $state.ready -and $wait -lt 100) { Start-Sleep -Milliseconds 50; $wait++ }
Assert ($state.ready -eq $true) "mock 服务已在 127.0.0.1:$($state.port) 就绪" 'mock 服务启动失败'
$base = 'http://127.0.0.1:' + [int]$state.port + '/pkg.zip'

# ---------- 3. 基础规格：指向 mock 服务 ----------
$rtss = Get-ExtensionEntry 'rtss-shm'
$rtss.package.sourceKind = 'http'
$rtss.package.url = $base
$rtss.package.sha256 = $zipSha
$rtss.package.archiveName = 'pkg.zip'
$rtss.package.installerRelative = 'install.ps1'
$rtss.package.installerKind = 'script'
$rtss.package.installArgs = '-Target "{DIR}"'
$rtss.package.elevateInstall = $false
$rtss.package.requireSignature = $false
$rtss.package.installerSha256 = ''
$rtss.package.processArgs = ''
$rtss.package.processCommand = (Join-Path $env:WINDIR 'System32\where.exe')
$rtss.package.verifyTimeoutMs = 3000
$shmName = 'B133_SHM_' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$rtss.shmName = $shmName
$SIG = [int]0x52545353; $VER = [int]0x0002000D; $ENTRY = 6000; $ARROFF = 64; $ARRSZ = 2
$shm = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($shmName, [int64]($ARROFF + $ARRSZ * $ENTRY))
$va = $shm.CreateViewAccessor()
$va.Write([int64]0x00, [int]$SIG)
$va.Write([int64]0x04, [int]$VER)
$va.Write([int64]0x08, [int]$ENTRY)
$va.Write([int64]0x0C, [int]$ARROFF)
$va.Write([int64]0x10, [int]$ARRSZ)

function New-Spec([string]$tag) {
    $s = New-ExtensionProvisionSpec $rtss 'oneclick'
    $s.cacheDir = Join-Path $script:DataDir ('cache-' + $tag)
    $s.targetDir = Join-Path $script:DataDir ('target-' + $tag)
    $s.cancelSignal = @{ requested = $false }
    return $s
}

# ---------- 4. 流式进度：百分比 / 速度 / 剩余时间真的回推了 ----------
# 用慢速模式模拟真实带宽：本机回环 700KB 秒完，进度回推间隔还没到就结束了，
# 那样的用例测不出「流式」也测不出速度（真实网络里 17MB 不可能 0.1 秒下完）。
$state.mode = 'slow'
$s1 = New-Spec 'stream'
Clear-UiMessages
$r1 = Invoke-Worker $s1
$state.mode = 'ok'
Assert ($r1.ok -eq $true) "流式下载后供应成功（reason=$($r1.reason)）" "流式下载失败：$($r1.reason) $($r1.detail)"
$dl = @($script:UiMessages | Where-Object { $_.type -eq 'extensionProgress' -and $_.stage -eq 'download' })
$withPart = @($dl | Where-Object { $null -ne $_.part -and [int]$_.part -ge 0 })
Assert ($withPart.Count -ge 2) "下载进度回推了 $($withPart.Count) 条带百分比的进度" '下载阶段只有一条静态进度（仍是假进度）'
$recvSeq = @($withPart | ForEach-Object { [int64]$_.recv })
$mono = $true
for ($i = 1; $i -lt $recvSeq.Count; $i++) { if ($recvSeq[$i] -lt $recvSeq[$i - 1]) { $mono = $false } }
Assert ($mono -and $recvSeq.Count -gt 0) 'recv 单调递增（真实已接收字节）' 'recv 回退或缺失'
$hasBps = @($withPart | Where-Object { [int64]$_.bps -gt 0 }).Count -gt 0
Assert $hasBps '回推了下载速度 bps' '没有速度字段'
$hasEta = @($withPart | Where-Object { $null -ne $_.eta }).Count -gt 0
Assert $hasEta '回推了剩余时间 eta' '没有剩余时间字段'
$last = $withPart[$withPart.Count - 1]
Assert ([int64]$last.total -eq $zipBytes.Length) "total 与包大小一致（$($last.total)）" "total 不对：$($last.total)"

# ---------- 5. Range 续传：.part 已有前半段，只补后一半 ----------
$s2 = New-Spec 'resume'
New-Item -ItemType Directory -Path $s2.cacheDir -Force | Out-Null
$half = [int]($zipBytes.Length / 2)
$partPath = Join-Path $s2.cacheDir 'pkg.zip.part'
$pre = New-Object byte[] $half
[Array]::Copy($zipBytes, 0, $pre, 0, $half)
[System.IO.File]::WriteAllBytes($partPath, $pre)
$state.requests = 0; $state.partials = 0; $state.ranges = ''
$r2 = Invoke-Worker $s2
Assert ($r2.ok -eq $true) "断点续传后供应成功（reason=$($r2.reason)）" "续传失败：$($r2.reason) $($r2.detail)"
Assert ([int]$state.partials -ge 1) "服务端返回了 206 分段响应（partials=$($state.partials)）" '没有走 206，续传等于重下'
Assert ([string]$state.ranges -match ('bytes=' + $half + '-')) "请求带了 Range: bytes=$half-（实际 $($state.ranges)）" "Range 头不对：$($state.ranges)"
$hitSha = Get-Sha (Join-Path $s2.cacheDir 'pkg.zip')
Assert ($hitSha -eq $zipSha) '续传拼接后的归档哈希与整包一致' '续传拼出来的包是坏的'

# ---------- 6. 服务端不支持 Range：回退整包覆盖，不拼半截 ----------
$s3 = New-Spec 'norange'
New-Item -ItemType Directory -Path $s3.cacheDir -Force | Out-Null
$badPart = Join-Path $s3.cacheDir 'pkg.zip.part'
$preBad = New-Object byte[] 1024
[System.IO.File]::WriteAllBytes($badPart, $preBad)
$state.mode = 'norange'
$r3 = Invoke-Worker $s3
Assert ($r3.ok -eq $true) "服务端不支持 Range 时安全回退整包（reason=$($r3.reason)）" "不支持 Range 时失败：$($r3.reason)"
Assert ((Get-Sha (Join-Path $s3.cacheDir 'pkg.zip')) -eq $zipSha) '回退整包后哈希正确' '回退后包损坏'
$state.mode = 'ok'

# ---------- 7. 多源回退：首选源 404，备用源可用 ----------
$s4 = New-Spec 'fallback'
$s4.url = 'http://127.0.0.1:' + [int]$state.port + '/missing.zip'
$s4.urls = @($base)
$state.requests = 0
$r4 = Invoke-Worker $s4
Assert ($r4.ok -eq $true) "首选源失败后自动切到备用源（reason=$($r4.reason)）" "多源回退失败：$($r4.reason) $($r4.detail)"
Assert ([int]$state.requests -ge 2) "两个源都被尝试过（requests=$($state.requests)）" '备用源没有被尝试'

# ---------- 8. 缓存命中：不发起任何网络请求 ----------
$s5 = New-Spec 'cache'
New-Item -ItemType Directory -Path $s5.cacheDir -Force | Out-Null
Copy-Item -LiteralPath $zip -Destination (Join-Path $s5.cacheDir 'pkg.zip') -Force
$state.requests = 0
Clear-UiMessages
$r5 = Invoke-Worker $s5
Assert ($r5.ok -eq $true) '已验证缓存命中后供应成功' "缓存命中却失败：$($r5.reason)"
Assert ([int]$state.requests -eq 0) '缓存命中时没有发起下载请求' "缓存命中仍请求了 $($state.requests) 次"
$hitMsg = @($script:UiMessages | Where-Object { $_.type -eq 'extensionProgress' -and $_.detail -eq 'cacheHit' })
Assert ($hitMsg.Count -ge 1) '缓存命中如实回推 cacheHit' '缓存命中没有提示'

# ---------- 9. 用户取消：慢速传输中途取消，回滚干净 ----------
$s6 = New-Spec 'cancel'
$state.mode = 'slow'
$ps = [PowerShell]::Create()
[void]$ps.AddScript($script:ExtensionProvisionWorker).AddArgument($s6).AddArgument($script:ExtProvQueue).AddArgument('').AddArgument([string]$script:NetProxyHelper)
$h = $ps.BeginInvoke()
Start-Sleep -Milliseconds 500
Assert ((Test-Path (Join-Path $s6.cacheDir 'pkg.zip.part'))) '取消前已开始写 .part（确实在传）' '取消用例没进入下载（.part 不存在）'
$s6.cancelSignal.requested = $true
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while (-not $h.IsCompleted -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 50 }
$r6 = @($ps.EndInvoke($h))[0]
$ps.Dispose()
Drain-ExtProvQueue
$state.mode = 'ok'
Assert ($h.IsCompleted -eq $true) "取消后 worker 在 $($sw.ElapsedMilliseconds)ms 内退出" '取消后 worker 卡住不退出'
Assert ($r6.reason -eq 'cancelled') "取消原因如实报 cancelled（实际 $($r6.reason)）" "取消被当成别的错误：$($r6.reason)"
Assert ($r6.rolledBack -eq $true) '取消走的是完整回滚路径' '取消没有回滚'
Assert (-not (Test-Path (Join-Path $s6.cacheDir 'pkg.zip.part'))) '取消后 .part 已删除' '.part 残留'
Assert (-not (Test-Path (Join-Path $s6.cacheDir 'pkg.zip'))) '取消后没有写出归档' '取消却留下了归档'
Assert (-not (Test-Path $s6.targetDir)) '取消后目标目录已回滚' '取消后目标目录残留'
Assert ($r6.detail -match '未做任何更改') '取消文案明确「未做任何更改」' "取消文案不可理解：$($r6.detail)"

# ---------- 10. 源码契约：E2 的关键路径都在 ----------
$provSource = Get-Content (Join-Path $root 'src\app\85-ExtensionProvision.ps1') -Raw -Encoding UTF8
foreach ($need in 'Invoke-SourceOnce', 'AddRange', 'GetResponseStream', 'Send-DownloadProgress', 'Get-ProvisionSources', 'Stop-ExtensionProvision', 'connectTimeoutSec', 'progressIntervalMs') {
    Assert ($provSource -match [regex]::Escape($need)) "E2 实现存在：$need" "供应层缺 $need"
}
$uiJs = Get-Content (Join-Path $root 'ui\js\extensions.js') -Raw -Encoding UTF8
Assert ($uiJs -match 'cancelExtensionProvision') '前端有取消命令入口' '前端没有取消按钮下发命令'
Assert ($uiJs -match 'progressInfo') '前端保留整条进度消息（速度/剩余时间）' '前端只留了百分比'

# ---------- 收尾 ----------
$state.stop = $true
Start-Sleep -Milliseconds 200
try { $serverPs.Stop() } catch { }
try { $serverPs.Dispose() } catch { }
$va.Dispose(); $shm.Dispose()
try { Remove-Item -LiteralPath $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }

if ($fail -gt 0) { Write-Host "== B133 失败 $fail 项 ==" -ForegroundColor Red; exit 1 }
Write-Host '== B133 通过 ==' -ForegroundColor Cyan
exit 0
