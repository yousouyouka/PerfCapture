# B136 下载可达性探针（2.1.8）：探测排序 / 死源快跳 / 断流换源续传 / 预算按体积推导 / 手动导入。
# 不联网：本地 TcpListener 起多个 mock HTTP 服务（可控延迟、限速、断流、404），直接驱动 worker。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b136-download-resilience.ps1

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host "== B136 下载可达性探针（探测 / 换源 / 续传 / 预算 / 手动导入）==" -ForegroundColor Cyan

# ---------- stub 宿主依赖 ----------
$script:Root = $root
$script:DataDir = Join-Path $env:TEMP ('PerfCapture-B136-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
$script:UiMessages = New-Object System.Collections.ArrayList
function Write-AppLog([string]$text, [string]$lvl = 'INFO') { }
function Send-ToUi([hashtable]$payload) { [void]$script:UiMessages.Add($payload) }
function Save-Config { }
$script:Cfg = @{ extensions = @{} }

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
    [void]$ps.AddScript($script:ExtensionProvisionWorker).AddArgument($S).AddArgument($script:ExtProvQueue)
    $r = @($ps.Invoke())[0]
    $ps.Dispose()
    Drain-ExtProvQueue
    return $r
}

# ---------- 1. 造包（约 700KB，够分块与限速） ----------
$work = Join-Path $script:DataDir 'fixture'
New-Item -ItemType Directory -Path $work -Force | Out-Null
Set-Content -LiteralPath (Join-Path $work 'install.ps1') -Value @'
param([string]$Target)
New-Item -ItemType Directory -Path $Target -Force | Out-Null
'@ -Encoding UTF8
$filler = New-Object byte[] (700 * 1024)
(New-Object System.Random(20261122)).NextBytes($filler)
[System.IO.File]::WriteAllBytes((Join-Path $work 'filler.bin'), $filler)
$zip = Join-Path $script:DataDir 'pkg.zip'
[void][System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem')
if (Test-Path $zip) { Remove-Item $zip -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($work, $zip)
$zipBytes = [System.IO.File]::ReadAllBytes($zip)
$zipSha = Get-Sha $zip
Write-Host ("  包大小 {0:N0} 字节 / SHA {1}" -f $zipBytes.Length, $zipSha.Substring(0, 12))

# ---------- 2. mock 服务：延迟 / 限速 / 断流 / 404 / 不支持 Range ----------
# 关键区分：探测请求固定带 `Range: bytes=0-0`，下载请求是 `bytes=N-` 或无 Range。
# 因此 probes / downloads 两个计数器能分别统计「探过」与「真的从它下过」。
$serverCode = @'
param([hashtable]$State, [byte[]]$Payload)
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$State.port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
$State.ready = $true
$len = $Payload.Length
while (-not $State.stop) {
    # 非阻塞 accept：$State.stop 一置位就能退出循环，runspace 自行结束（不靠 Stop/Dispose 强杀）
    try { if (-not $listener.Pending()) { Start-Sleep -Milliseconds 40; continue } } catch { break }
    try { $client = $listener.AcceptTcpClient() } catch { break }
    try {
        $ns = $client.GetStream()
        $ns.ReadTimeout = 8000
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
        $State.hits = [int]$State.hits + 1
        if ($State.headerDelayMs -gt 0) { Start-Sleep -Milliseconds ([int]$State.headerDelayMs) }
        $range = ''
        if ($hdrs.ContainsKey('range')) { $range = [string]$hdrs['range'] }
        if ($range -eq 'bytes=0-0') { $State.probes = [int]$State.probes + 1 } else { $State.downloads = [int]$State.downloads + 1 }
        if ($State.mode -eq 'notfound') {
            $body = [System.Text.Encoding]::ASCII.GetBytes('not found')
            $h = "HTTP/1.1 404 Not Found`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
            $hb = [System.Text.Encoding]::ASCII.GetBytes($h)
            $ns.Write($hb, 0, $hb.Length); $ns.Write($body, 0, $body.Length); $ns.Flush()
            continue
        }
        $start = 0
        if ($range -match 'bytes=(\d+)-') { $start = [int]$Matches[1] }
        if ($State.mode -eq 'norange') { $start = 0 }
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
        $sent = 0
        $chunk = 32768
        while ($off -lt $len) {
            if ($State.stop) { break }
            if ($State.stallAfter -gt 0 -and $sent -ge $State.stallAfter) {
                $waited = 0
                while ($waited -lt 30000 -and -not $State.stop) { Start-Sleep -Milliseconds 50; $waited += 50 }
                break
            }
            $n = [math]::Min($chunk, $len - $off)
            $ns.Write($Payload, $off, $n)
            $ns.Flush()
            $off += $n; $sent += $n
            if ($State.rateBps -gt 0) { Start-Sleep -Milliseconds ([int][math]::Max(1, (1000.0 * $n / [double]$State.rateBps))) }
        }
    } catch { } finally { try { $client.Close() } catch { } }
}
try { $listener.Stop() } catch { }
'@

function New-Mock([hashtable]$cfg) {
    $st = @{ ready = $false; stop = $false; port = 0; mode = 'ok'; hits = 0; probes = 0; downloads = 0; partials = 0
        headerDelayMs = 0; rateBps = 0; stallAfter = 0 }
    foreach ($k in $cfg.Keys) { $st[$k] = $cfg[$k] }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($serverCode).AddArgument($st).AddArgument($zipBytes)
    $h = $ps.BeginInvoke()
    $wait = 0
    while (-not $st.ready -and $wait -lt 100) { Start-Sleep -Milliseconds 50; $wait++ }
    return @{ state = $st; ps = $ps; handle = $h; url = ('http://127.0.0.1:' + [int]$st.port + '/pkg.zip') }
}

function Stop-Mock($m) {
    try { $m.state.stop = $true } catch { }
    try { $m.ps.Stop() } catch { }
    try { $m.ps.Dispose() } catch { }
}

# ---------- 3. 基础规格 ----------
$rtss = Get-ExtensionEntry 'rtss-shm'
$rtss.package.sourceKind = 'http'
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
$rtss.package.pageUrl = 'https://example.invalid/rtss'
$shmName = 'B136_SHM_' + [guid]::NewGuid().ToString('N').Substring(0, 12)
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

$fast = New-Mock @{}
$dead = New-Mock @{ mode = 'notfound' }
$slow = New-Mock @{ headerDelayMs = 4000 }
$stall = New-Mock @{ stallAfter = 200000 }
$throttle = New-Mock @{ rateBps = 250000 }
# 断流用例的备用源故意慢 400ms 回头：保证探测把它排在断流源之后，才测得到「换源」
$backup = New-Mock @{ headerDelayMs = 400 }
Assert ($fast.state.ready -and $dead.state.ready -and $slow.state.ready -and $stall.state.ready -and $throttle.state.ready -and $backup.state.ready) '6 个 mock 服务就绪' 'mock 服务启动失败'

# ---------- 4. 探测排序：慢源（4s 才回头）不该被选中下载 ----------
$s1 = New-Spec 'probe'
$s1.url = $slow.url
$s1.urls = @($fast.url)
$s1.probeTimeoutMs = 2500
$r1 = Invoke-Worker $s1
Assert ($r1.ok -eq $true) "探测后从可用源完成下载（reason=$($r1.reason)）" "探测用例失败：$($r1.reason) $($r1.detail)"
Assert ([int]$fast.state.downloads -ge 1) "快源承担了下载（downloads=$($fast.state.downloads)）" '快源没有收到下载请求'
Assert ([int]$slow.state.downloads -eq 0) "慢源没有承担下载（downloads=$($slow.state.downloads)）" "慢源被选中下载了 $($slow.state.downloads) 次"
Assert ([int]$slow.state.hits -ge 1) '慢源仍被探测过（用于排序）' '慢源连探测请求都没收到，排序逻辑没跑'

# ---------- 5. 死源快跳：404 源不消耗连接超时，直接换下一个 ----------
$s2 = New-Spec 'deadfirst'
$s2.url = $dead.url
$s2.urls = @($fast.url)
$s2.probeTimeoutMs = 2500
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r2 = Invoke-Worker $s2
$sw.Stop()
Assert ($r2.ok -eq $true) "首选源 404 时换源成功（reason=$($r2.reason)）" "死源用例失败：$($r2.reason) $($r2.detail)"
Assert ($sw.ElapsedMilliseconds -lt 12000) "死源 + 成功下载总耗时 $([int]$sw.ElapsedMilliseconds)ms（预算 12s）" "耗时 $([int]$sw.ElapsedMilliseconds)ms，探测没起作用"

# ---------- 6. 断流换源：A 发 200KB 后挂起，B 用 Range 接着下 ----------
$s3 = New-Spec 'stall'
$s3.url = $stall.url
$s3.urls = @($backup.url)
$s3.probeTimeoutMs = 1500
$s3.stallTimeoutSec = 5
$s3.timeoutSec = 300
$backup.state.downloads = 0
$backup.state.partials = 0
$r3 = Invoke-Worker $s3
Assert ($r3.ok -eq $true) "断流后换源并完成（reason=$($r3.reason)）" "断流换源失败：$($r3.reason) $($r3.detail)"
Assert ([int]$backup.state.partials -ge 1) "备用源收到 Range 续传请求（partials=$($backup.state.partials)）" '备用源没有走续传，等于重下'
Assert ((Get-Sha (Join-Path $s3.cacheDir 'pkg.zip')) -eq $zipSha) '跨源续传拼出的包哈希正确' '跨源续传拼坏了'

# ---------- 7. 预算按体积推导：timeoutSec=1 也能下完 700KB ----------
$s4 = New-Spec 'budget'
$s4.url = $throttle.url
$s4.urls = @()
$s4.timeoutSec = 1          # 固定预算下 700KB 必死；现在由体积推导
$s4.stallTimeoutSec = 20
$r4 = Invoke-Worker $s4
Assert ($r4.ok -eq $true) "固定预算 1s 仍能下完（实际按体积给预算）" "预算仍被写死：$($r4.reason) $($r4.detail)"

# ---------- 8. 全源不可达：文案带探测事实 + 手动导入提示 ----------
$s5 = New-Spec 'allsdead'
$s5.url = $dead.url
$s5.urls = @($dead.url + '?mirror=1')
$s5.probeTimeoutMs = 1500
$r5 = Invoke-Worker $s5
Assert ($r5.ok -eq $false) '全源不可达时如实失败（不假装成功）' '全源不可达却返回成功'
Assert ([string]$r5.detail -match '探测：') "失败详情带上探测事实（$([string]$r5.detail)）" '失败详情没有探测事实'
Assert ([string]$r5.detail -match '手动导入') '失败详情提示可手动导入' '失败详情没有给出手动导入出路'

# ---------- 9. 失败保留 .part：网络恢复后重试能续传，不从 0 开始 ----------
# 用一台全新的断流服务：mock 是单线程的，上一台还在为第 6 步的连接 sleep，不能再借。
$stall2 = New-Mock @{ stallAfter = 180000 }
$s7 = New-Spec 'keepPart'
$s7.url = $stall2.url
$s7.urls = @()
$s7.stallTimeoutSec = 5
$s7.timeoutSec = 60
$r7 = Invoke-Worker $s7
$p7 = Join-Path $s7.cacheDir 'pkg.zip.part'
Assert ($r7.ok -eq $false) '单源断流时如实失败' '单源断流却成功了'
Assert (Test-Path -LiteralPath $p7) '.part 在下载失败后被保留（可续传）' '下载失败把已下好的部分也删了'
$partLen = 0
try { $partLen = (Get-Item -LiteralPath $p7).Length } catch { }
Assert ($partLen -gt 0) "保留的 .part 有 $partLen 字节" '保留的 .part 是空的'

# 同一 cacheDir 换成可用源重试：应从已下位置用 Range 续，而不是重下整包
$backup.state.partials = 0
$s7.url = $backup.url
$s7.urls = @()
$r7b = Invoke-Worker $s7
Assert ($r7b.ok -eq $true) "重试续传后供应成功（reason=$($r7b.reason)）" "重试失败：$($r7b.reason) $($r7b.detail)"
Assert ([int]$backup.state.partials -ge 1) "重试时服务端收到 Range 续传（partials=$($backup.state.partials)）" '重试时整包重下了'

# ---------- 10. 手动导入：本地包走同一条流水线 ----------
$s6 = New-Spec 'localok'
$s6.sourceKind = 'file'
$s6.allowLocalSource = $true
$s6.url = $zip
$r6 = Invoke-Worker $s6
Assert ($r6.ok -eq $true) "手动导入本地包成功（reason=$($r6.reason)）" "本地导入失败：$($r6.reason) $($r6.detail)"

# 宿主侧预检：哈希不符要当场拒绝，且给出期望/实际
$chk = Test-ExtensionPackageFile 'rtss-shm' $zip
Assert ($chk.ok -eq $true) '预检：正确的包通过' "预检误拒：$($chk.reason) $($chk.detail)"
$badFile = Join-Path $script:DataDir 'wrong.bin'
[System.IO.File]::WriteAllBytes($badFile, [byte[]](1..64))
$chk2 = Test-ExtensionPackageFile 'rtss-shm' $badFile
Assert ($chk2.ok -eq $false -and $chk2.reason -eq 'hashMismatch') "预检：错误文件被判 hashMismatch（$($chk2.detail)）" "错误文件没被拦住：$($chk2.ok) $($chk2.reason)"
$chk3 = Test-ExtensionPackageFile 'rtss-shm' (Join-Path $script:DataDir 'nope.zip')
Assert ($chk3.ok -eq $false -and $chk3.reason -eq 'localPackageMissing') '预检：不存在的文件被判 localPackageMissing' "缺失文件判定不对：$($chk3.reason)"

# ---------- 10. 配置守卫：RTSS 必须真的配了备用源 ----------
$reg = Get-Content (Join-Path $root 'extensions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$rp = @($reg.extensions | Where-Object { $_.id -eq 'rtss-shm' })[0].package
Assert (@($rp.urls).Count -ge 2) "RTSS 配置了 $(@($rp.urls).Count) 个备用源（不再单源裸奔）" 'RTSS 仍然只有 1 个源'
Assert ([int]$rp.connectTimeoutSec -ge 15) "连接超时放宽到 $($rp.connectTimeoutSec)s" '连接超时仍是 8s'
Assert ([bool]$rp.pageUrl) '配置了官方下载页（手动导入兜底）' '没有 pageUrl'

# 先给结论再清理：清理涉及停止 runspace / 删临时目录，不该影响判定结果。
Write-Host ''
if ($fail -eq 0) { Write-Host '== B136 全部通过 ==' -ForegroundColor Green }
else { Write-Host "== B136 失败 $fail 项 ==" -ForegroundColor Red }

$ErrorActionPreference = 'SilentlyContinue'
# 置停止标志后等 runspace 自行结束（非阻塞 accept + stop 感知的 stall），
# 不调 Stop/Dispose —— 对阻塞中的 runspace 强停会让子进程异常退出，把「通过」变成「进程失败」。
$mocks = @($fast, $dead, $slow, $stall, $throttle, $backup, $stall2)
foreach ($m in $mocks) { try { $m.state.stop = $true } catch { } }
$waitUntil = (Get-Date).AddSeconds(4)
foreach ($m in $mocks) {
    while (-not $m.handle.IsCompleted -and (Get-Date) -lt $waitUntil) { Start-Sleep -Milliseconds 40 }
}
try { Remove-Item -LiteralPath $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }

if ($fail -eq 0) { exit 0 }
exit 1
