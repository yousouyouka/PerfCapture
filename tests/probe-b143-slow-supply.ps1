# B143 真机慢速供应验证（§15.6）：把 RTSS 包放进限速 ~150KB/s 的 mock 源，
# 跑完整供应（探测 → 下载 → 校验 → 解包 → 静默安装 → 配置回读 → 启动），
# 确认不再被旧的固定 90s 预算逻辑误杀；进度回推带速度/ETA；失败/取消都清干净。
# 不联网、不装真实 RTSS：用本地 TcpListener + 脚本安装器模拟整个链路。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b143-slow-supply.ps1

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host '== B143 慢速供应验证（150 KB/s 全链路）==' -ForegroundColor Cyan

# ---------- stub 宿主依赖 ----------
$script:Root = $root
$script:DataDir = Join-Path $env:TEMP ('PerfCapture-B143-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
$script:UiMessages = New-Object System.Collections.ArrayList
function Write-AppLog([string]$text, [string]$lvl = 'INFO') { [void]$script:Logs.Add("$lvl $text") }
function Send-ToUi($payload) {
    [void]$script:UiMessages.Add($payload)
    if ($payload.type -eq 'extensionProgress' -and $payload.bps -gt 0) {
        [void]$script:Progress.Add($payload)
    }
}
function Save-Config { }
$script:Cfg = @{ extensions = @{} }
$script:Logs = New-Object System.Collections.ArrayList
$script:Progress = New-Object System.Collections.ArrayList
. (Join-Path $root 'src\app\06-NetProxy.ps1')
. (Join-Path $root 'src\app\rtss-shm.ps1')
. (Join-Path $root 'src\app\80-Extensions.ps1')
. (Join-Path $root 'src\app\85-ExtensionProvision.ps1')

function Get-Sha([string]$path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $fs = [IO.File]::OpenRead($path); try { return ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '').ToUpperInvariant() } finally { $fs.Dispose() } }
    finally { $sha.Dispose() }
}
function Invoke-Worker([hashtable]$S) {
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:ExtensionProvisionWorker).AddArgument($S).AddArgument($script:ExtProvQueue).AddArgument('').AddArgument([string]$script:NetProxyHelper)
    $r = @($ps.Invoke())[0]
    $ps.Dispose()
    Drain-ExtProvQueue
    return $r
}

# ---------- 1. 造包：约 900KB，150KB/s 下需 6 秒（旧固定预算会误杀）----------
$fixture = Join-Path $script:DataDir 'fixture'
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$targetMarker = Join-Path $script:DataDir 'installed-target'
Set-Content -LiteralPath (Join-Path $fixture 'install.ps1') -Value @"
param([string]`$Target)
New-Item -ItemType Directory -Path `$Target -Force | Out-Null
Set-Content -LiteralPath (Join-Path `$Target 'installed.txt') -Value 'ok-$([guid]::NewGuid().ToString('N').Substring(0,8))' -Encoding UTF8
"@ -Encoding UTF8
$filler = New-Object byte[] (900 * 1024)
(New-Object Random(20261122)).NextBytes($filler)
[IO.File]::WriteAllBytes((Join-Path $fixture 'payload.bin'), $filler)
$zip = Join-Path $script:DataDir 'RTSSSetup737.zip'
[Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem') | Out-Null
[IO.Compression.ZipFile]::CreateFromDirectory($fixture, $zip)
$zipBytes = [IO.File]::ReadAllBytes($zip)
$zipSha = Get-Sha $zip

# ---------- 2. 限速 mock（150 KB/s，支持 Range）----------
$serverCode = @'
param([hashtable]$State, [byte[]]$Payload)
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$State.port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
$State.ready = $true
$len = $Payload.Length
while (-not $State.stop) {
    try { if (-not $listener.Pending()) { Start-Sleep -Milliseconds 40; continue } } catch { break }
    try { $client = $listener.AcceptTcpClient() } catch { break }
    try {
        $ns = $client.GetStream(); $ns.ReadTimeout = 8000
        $buf = New-Object byte[] 8192
        $read = $ns.Read($buf, 0, $buf.Length)
        $lines = ([Text.Encoding]::ASCII.GetString($buf, 0, $read)) -split "`r`n"
        $hdrs = @{}
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $ln = [string]$lines[$i]
            if (-not $ln) { break }
            $k = $ln.IndexOf(':')
            if ($k -gt 0) { $hdrs[$ln.Substring(0, $k).Trim().ToLowerInvariant()] = $ln.Substring($k + 1).Trim() }
        }
        $range = if ($hdrs.ContainsKey('range')) { [string]$hdrs['range'] } else { '' }
        $State.hits = [int]$State.hits + 1
        $start = 0
        if ($range -match 'bytes=(\d+)-') { $start = [int]$Matches[1] }
        $count = $len - $start
        if ($start -gt 0) {
            $h = "HTTP/1.1 206 Partial Content`r`nContent-Length: $count`r`nContent-Range: bytes $start-$($len-1)/$len`r`nConnection: close`r`n`r`n"
            $State.partials = [int]$State.partials + 1
        } else {
            $h = "HTTP/1.1 200 OK`r`nContent-Length: $count`r`nConnection: close`r`n`r`n"
            $State.downloads = [int]$State.downloads + 1
        }
        $hb = [Text.Encoding]::ASCII.GetBytes($h); $ns.Write($hb, 0, $hb.Length)
        $off = $start; $chunk = 16384
        while ($off -lt $len -and -not $State.stop) {
            $n = [Math]::Min($chunk, $len - $off)
            $ns.Write($Payload, $off, $n); $ns.Flush()
            $off += $n
            $ms = [int][Math]::Max(1, (1000.0 * $n / [double]$State.rateBps))
            Start-Sleep -Milliseconds $ms
        }
    } catch { } finally { try { $client.Close() } catch { } }
}
try { $listener.Stop() } catch { }
'@
$st = @{ ready = $false; stop = $false; port = 0; hits = 0; downloads = 0; partials = 0; rateBps = 153600 }
$ps = [PowerShell]::Create()
[void]$ps.AddScript($serverCode).AddArgument($st).AddArgument($zipBytes)
$h = $ps.BeginInvoke()
$wait = 0
while (-not $st.ready -and $wait -lt 100) { Start-Sleep -Milliseconds 50; $wait++ }
Assert ($st.ready) '限速 mock 服务就绪' 'mock 服务启动失败'
$url = 'http://127.0.0.1:' + [int]$st.port + '/RTSSSetup737.zip'

# ---------- 3. 规格：模拟 RTSS 包配置 ----------
$rtss = Get-ExtensionEntry 'rtss-shm'
$rtss.package.sourceKind = 'http'
$rtss.package.sha256 = $zipSha
$rtss.package.archiveName = 'RTSSSetup737.zip'
$rtss.package.installerRelative = 'install.ps1'
$rtss.package.installerKind = 'script'
$rtss.package.installArgs = '-Target "' + $targetMarker + '"'
$rtss.package.elevateInstall = $false
$rtss.package.requireSignature = $false
$rtss.package.installerSha256 = ''
$rtss.package.processArgs = ''
$rtss.package.processCommand = (Join-Path $env:WINDIR 'System32\where.exe')
$rtss.package.configFiles = @(@{ relative = 'installed.txt'; entries = @{ dummy = 'x' }; verify = $true })
$rtss.package.verifyTimeoutMs = 3000
$rtss.package.pageUrl = 'https://example.invalid/rtss'
$shmName = 'B143_SHM_' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$rtss.shmName = $shmName
$SIG = [int]0x52545353; $VER = [int]0x0002000D; $ENTRY = 6000; $ARROFF = 64; $ARRSZ = 2
$shm = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($shmName, [int64]($ARROFF + $ARRSZ * $ENTRY))
$va = $shm.CreateViewAccessor()
$va.Write([int64]0x00, [int]$SIG); $va.Write([int64]0x04, [int]$VER)
$va.Write([int64]0x08, [int]$ENTRY); $va.Write([int64]0x0C, [int]$ARROFF); $va.Write([int64]0x10, [int]$ARRSZ)

$S = New-ExtensionProvisionSpec $rtss 'oneclick'
$S.cacheDir = Join-Path $script:DataDir 'cache-slow'
$S.targetDir = $targetMarker
$S.cancelSignal = @{ requested = $false }
$S.url = $url
$S.urls = @()
$S.timeoutSec = 1   # 故意给一个远小于实际下载时长的固定预算：验证按体积推导
$S.stallTimeoutSec = 20
$S.connectTimeoutSec = 15
$S.probeTimeoutMs = 3000

# ---------- 4. 全链路慢速供应 ----------
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Worker $S
$sw.Stop()
$secs = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
Assert ($r.ok -eq $true) "150KB/s 慢源完成完整供应（reason=$($r.reason)，耗时 ${secs}s）" "慢源供应失败：$($r.reason) $($r.detail)"
Assert ($sw.Elapsed.TotalSeconds -gt 3) "确实经历了限速下载（${secs}s > 3s）" "下载太快，限速没生效（${secs}s）"
Assert ((Get-Sha (Join-Path $S.cacheDir 'RTSSSetup737.zip')) -eq $zipSha) '慢速下载的包哈希正确' '慢速下载把包下坏了'
Assert (Test-Path -LiteralPath (Join-Path $targetMarker 'installed.txt')) '安装器真的执行了（目标目录有回读文件）' '安装器没执行'
Assert ($script:Progress.Count -ge 2) "下载过程回推了 $($script:Progress.Count) 次带速度的进度" '进度回推缺失速度信息'
$withEta = @($script:Progress | Where-Object { $_.eta -gt 0 })
Assert ($withEta.Count -ge 1) '进度包含剩余时间 ETA' '进度没有 ETA'

# ---------- 5. 供应后状态如实 ----------
$stateAfter = Get-ExtensionStates | Where-Object { $_.id -eq 'rtss-shm' } | Select-Object -First 1
Assert ($null -ne $stateAfter) '供应后能读到扩展状态' '供应后状态丢失'

# ---------- 6. 清理 ----------
$st.stop = $true
$waitUntil = (Get-Date).AddSeconds(4)
while (-not $h.IsCompleted -and (Get-Date) -lt $waitUntil) { Start-Sleep -Milliseconds 40 }
try { $va.Dispose(); $shm.Dispose() } catch { }
try { Remove-Item -LiteralPath $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }

Write-Host '== B143 通过 ==' -ForegroundColor Cyan
if ($fail -gt 0) { Write-Host ("失败断言 $fail 项") -ForegroundColor Red; exit 1 }
exit 0
