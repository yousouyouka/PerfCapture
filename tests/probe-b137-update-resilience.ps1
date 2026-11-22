# B137 更新下载韧性探针（2.1.8）：探测排序 / 死源接力 / 跨源续传 / 尺寸守卫 / 取消。
# 直接驱动 70-Updates.ps1 里的 $script:UpdateDownloadScript（不启动整个宿主），用本地 mock 服务喂数据。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b137-update-resilience.ps1

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host "== B137 更新下载韧性探针（探测 / 接力 / 续传 / 守卫 / 取消）==" -ForegroundColor Cyan

$work = Join-Path $env:TEMP ('PerfCapture-B137-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

# ---------- 1. 从宿主源码里取出下载脚本（唯一实现，不复制粘贴） ----------
$src = [IO.File]::ReadAllText((Join-Path $root 'src\app\70-Updates.ps1'))
$i = $src.IndexOf("`$script:UpdateDownloadScript = @'")
Assert ($i -ge 0) '找到 UpdateDownloadScript 定义' '源码里找不到 UpdateDownloadScript'
$s0 = $src.IndexOf("`n", $i) + 1
$e0 = $src.IndexOf("`n'@", $s0)
$body = $src.Substring($s0, $e0 - $s0)
$runner = [scriptblock]::Create($body)
# M1：下载 worker 现在需要代理助手源码（宿主运行时由 06-NetProxy.ps1 提供）
$proxyHelper = [IO.File]::ReadAllText((Join-Path $root 'src\app\06-NetProxy.ps1'))

# ---------- 2. 造 1.5MB 负载（分块足够多次，能测出限速与断流） ----------
$payload = New-Object byte[] (1536 * 1024)
(New-Object System.Random(20261122)).NextBytes($payload)
$payloadSha = ([BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($payload))).Replace('-', '').ToLowerInvariant()
Write-Host ("  负载 {0:N0} 字节 / SHA {1}" -f $payload.Length, $payloadSha.Substring(0, 12))

$serverCode = @'
param([hashtable]$State, [byte[]]$Payload)
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$State.port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
$State.ready = $true
$len = $Payload.Length
while (-not $State.stop) {
    # 非阻塞 accept：stop 置位即可退出（不依赖父进程 Stop 强杀）
    try { if (-not $listener.Pending()) { Start-Sleep -Milliseconds 40; continue } } catch { break }
    try { $client = $listener.AcceptTcpClient() } catch { break }
    try {
        $ns = $client.GetStream()
        $ns.ReadTimeout = 8000
        $buf = New-Object byte[] 8192
        $read = $ns.Read($buf, 0, $buf.Length)
        $text = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
        $lines = $text -split "`r`n"
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
            $body404 = [System.Text.Encoding]::ASCII.GetBytes('no')
            $h404 = "HTTP/1.1 404 Not Found`r`nContent-Length: $($body404.Length)`r`nConnection: close`r`n`r`n"
            $hb404 = [System.Text.Encoding]::ASCII.GetBytes($h404)
            $ns.Write($hb404, 0, $hb404.Length); $ns.Write($body404, 0, $body404.Length); $ns.Flush()
            continue
        }
        $start = 0
        if ($range -match 'bytes=(\d+)-') { $start = [int]$Matches[1] }
        if ($start -ge $len -and $start -gt 0) {
            $h416 = "HTTP/1.1 416 Range Not Satisfiable`r`nContent-Range: bytes */$len`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
            $hb416 = [System.Text.Encoding]::ASCII.GetBytes($h416)
            $ns.Write($hb416, 0, $hb416.Length); $ns.Flush()
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
    [void]$ps.AddScript($serverCode).AddArgument($st).AddArgument($payload)
    $h = $ps.BeginInvoke()
    $wait = 0
    while (-not $st.ready -and $wait -lt 100) { Start-Sleep -Milliseconds 50; $wait++ }
    return @{ state = $st; ps = $ps; handle = $h; url = ('http://127.0.0.1:' + [int]$st.port + '/PerfCapture-Setup.exe') }
}
function Stop-Mock($m) { try { $m.state.stop = $true } catch { }; try { $m.ps.Stop() } catch { }; try { $m.ps.Dispose() } catch { } }

$fast = New-Mock @{}
$dead = New-Mock @{ mode = 'notfound' }
$slow = New-Mock @{ headerDelayMs = 3500 }
$stall = New-Mock @{ stallAfter = 300000 }
$backup = New-Mock @{ headerDelayMs = 400 }
$short = New-Mock @{ rateBps = 0 }
Assert ($fast.state.ready -and $dead.state.ready -and $slow.state.ready -and $stall.state.ready -and $backup.state.ready -and $short.state.ready) '6 个 mock 服务就绪' 'mock 服务启动失败'

$hosts = @('127.0.0.1')
function Invoke-Dl([string[]]$urls, [string]$tag, [long]$expectSize, [long]$maxBytes, [int]$probeMs, [int]$stallSec, $token) {
    $out = Join-Path $work ($tag + '.exe')
    $part = $out + '.part'
    return (& $runner -Urls $urls -OutPath $out -PartPath $part -MaxBytes $maxBytes -ExpectedSize $expectSize `
            -AllowedHosts $hosts -Token $token -ProbeMs $probeMs -StallSec $stallSec -NetProxyHelper $proxyHelper)[0]
}

$cts = New-Object System.Threading.CancellationTokenSource

# ---------- 3. 探测排序：慢源不承担下载 ----------
$r1 = Invoke-Dl @($slow.url, $fast.url) 'probe' $payload.Length 62914560 2000 20 $cts.Token
Assert ($r1.ok -eq $true) "探测后下载成功（err=$($r1.err)）" "下载失败：$($r1.err)"
Assert ([string]$r1.sha256 -eq $payloadSha) '整包 SHA-256 与负载一致' "SHA 不符：$($r1.sha256)"
Assert ([int]$fast.state.downloads -ge 1 -and [int]$slow.state.downloads -eq 0) "快源下载 / 慢源只探测（fast=$($fast.state.downloads) slow=$($slow.state.downloads)）" "排序没生效：fast=$($fast.state.downloads) slow=$($slow.state.downloads)"
Assert (@($r1.log | Where-Object { $_ -match '^probe ' }).Count -ge 2) '日志里每个源都有探测结论' '日志缺探测结论'

# ---------- 4. 死源接力：404 不拖垮整次下载 ----------
$dead.state.downloads = 0
$r2 = Invoke-Dl @($dead.url, $fast.url) 'deadfirst' $payload.Length 62914560 2000 20 $cts.Token
Assert ($r2.ok -eq $true) "首选源 404 时由备用源完成（err=$($r2.err)）" "死源接力失败：$($r2.err)"
Assert ([string]$r2.sha256 -eq $payloadSha) '接力后的包哈希正确' '接力后包损坏'

# ---------- 5. 跨源续传：A 断流后用 Range 从 B 接着下 ----------
$backup.state.downloads = 0
$backup.state.partials = 0
$r3 = Invoke-Dl @($stall.url, $backup.url) 'stall' $payload.Length 62914560 1200 5 $cts.Token
Assert ($r3.ok -eq $true) "断流后换源完成（err=$($r3.err)）" "断流换源失败：$($r3.err)"
Assert ([int]$backup.state.partials -ge 1) "备用源收到 Range 续传（partials=$($backup.state.partials)）" '没有续传，等于整包重下'
Assert ([string]$r3.sha256 -eq $payloadSha) '续传拼出的包哈希正确' '续传拼坏了'
$partLeft = Test-Path (Join-Path $work 'stall.exe.part')
Assert (-not $partLeft) '.part 成功后被转正（不残留）' '成功后仍残留 .part'

# ---------- 6. 尺寸守卫：声明大小与实收不符要判失败 ----------
$r4 = Invoke-Dl @($fast.url) 'sizeguard' ($payload.Length + 12345) 62914560 2000 20 $cts.Token
Assert ($r4.ok -eq $false) '尺寸不符被判失败' '尺寸不符却当成成功'

# ---------- 7. 上限守卫：超过 MaxBytes 立刻中止 ----------
$r5 = Invoke-Dl @($fast.url) 'toolarge' 0 65536 2000 20 $cts.Token
Assert ($r5.ok -eq $false -and [string]$r5.err -eq 'TOO_LARGE') "超过 MaxBytes 判 TOO_LARGE（err=$($r5.err)）" "上限没生效：$($r5.err)"

# ---------- 8. 取消：置 token 后中断，且不留 .part ----------
$cts2 = New-Object System.Threading.CancellationTokenSource
$slowDl = New-Mock @{ rateBps = 150000 }
$ps = [PowerShell]::Create()
[void]$ps.AddScript($body)
[void]$ps.AddParameter('Urls', @($slowDl.url))
[void]$ps.AddParameter('OutPath', (Join-Path $work 'cancel.exe'))
[void]$ps.AddParameter('PartPath', (Join-Path $work 'cancel.exe.part'))
[void]$ps.AddParameter('MaxBytes', 62914560)
[void]$ps.AddParameter('ExpectedSize', $payload.Length)
[void]$ps.AddParameter('AllowedHosts', $hosts)
[void]$ps.AddParameter('Token', $cts2.Token)
[void]$ps.AddParameter('ProbeMs', 1000)
[void]$ps.AddParameter('StallSec', 20)
[void]$ps.AddParameter('NetProxyHelper', $proxyHelper)
$h = $ps.BeginInvoke()
Start-Sleep -Milliseconds 700
$cts2.Cancel()
$rc = $null
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while (-not $h.IsCompleted -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 50 }
try { $rc = @($ps.EndInvoke($h))[0] } catch { }
$ps.Dispose()
Assert ($rc -and [string]$rc.err -eq 'CANCELLED') "取消后返回 CANCELLED（err=$($rc.err)）" "取消没生效：$($rc.err)"
Assert (-not (Test-Path (Join-Path $work 'cancel.exe.part'))) '取消后 .part 已删除' '取消后仍残留 .part'

# ---------- 9. 宿主侧接线：进度读 .part、看门狗 45s、取消删 .part ----------
$hostSrc = [IO.File]::ReadAllText((Join-Path $root 'src\app\70-Updates.ps1'))
Assert ($hostSrc -match 'Test-Path -LiteralPath \$ctx\.Part') '宿主进度读的是 .part' '宿主还在读最终文件（下载期间永远是 0）'
Assert ($hostSrc -match 'TotalSeconds -gt 45') '停滞看门狗为 45 秒' '看门狗阈值没改'
Assert ($hostSrc -match "AddParameter\('StallSec', 12\)") '换源停滞阈值 12 秒（60s 的旧值已消失）' '停滞阈值不是 12 秒'
Assert ($hostSrc -match "AddParameter\('ProbeMs', 6000\)") '探测预算 6 秒' '探测预算不对'
Assert ($hostSrc -match 'bps = \$bps; eta = \$eta') '进度消息带上速度与剩余时间' '没有速度/剩余时间字段'
$uiSrc = [IO.File]::ReadAllText((Join-Path $root 'ui\js\update.js'))
Assert ($uiSrc -match 'update\.speedEta') '界面显示速度与剩余时间' '界面没有速度/剩余时间'
Assert ($uiSrc -match "phase === 'downloading'") '下载中按钮变成取消' '下载中没有取消入口'

# 先给结论再清理：停 runspace / 删临时目录失败不该影响判定结果。
Write-Host ''
if ($fail -eq 0) { Write-Host '== B137 全部通过 ==' -ForegroundColor Green }
else { Write-Host "== B137 失败 $fail 项 ==" -ForegroundColor Red }

$ErrorActionPreference = 'SilentlyContinue'
# 置停止标志后等 runspace 自行结束（原因同 B136：强停阻塞中的 runspace 会让进程异常退出）。
$mocks = @($fast, $dead, $slow, $stall, $backup, $short, $slowDl)
foreach ($m in $mocks) { try { $m.state.stop = $true } catch { } }
$waitUntil = (Get-Date).AddSeconds(4)
foreach ($m in $mocks) {
    while (-not $m.handle.IsCompleted -and (Get-Date) -lt $waitUntil) { Start-Sleep -Milliseconds 40 }
}
try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }

if ($fail -eq 0) { exit 0 }
exit 1
