# B140 M3（B 全量实现）：jsDelivr wrapper 回退资产的结构校验、解包校验与端到端回退安装链路。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b140-wrapper-fallback.ps1

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$repoRoot = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host '== B140 M3 wrapper 回退探针 ==' -ForegroundColor Cyan

$work = Join-Path $env:TEMP ('PerfCapture-B140-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
. (Join-Path $repoRoot 'src\app\68-UpdateWrapper.ps1')

# ---------- 1. 造内层 Setup 与 wrapper ----------
$setupName = 'PerfCapture-Setup-2.1.9.exe'
$setupPath = Join-Path $work $setupName
$exe = New-Object byte[] 65536
(New-Object System.Random(20261122)).NextBytes($exe)
[IO.File]::WriteAllBytes($setupPath, $exe)
$setupSha = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()

$wrapperName = 'PerfCapture-Update-2.1.9.zip'
$wrapperPath = Join-Path $work $wrapperName
function New-Wrapper([string]$path, [string]$entryName, [byte[]]$bytes) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    $za = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $e = $za.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
        $s = $e.Open()
        try { $s.Write($bytes, 0, $bytes.Length) } finally { $s.Dispose() }
    } finally { $za.Dispose() }
}
New-Wrapper $wrapperPath $setupName $exe
$wrapperSha = (Get-FileHash -LiteralPath $wrapperPath -Algorithm SHA256).Hash.ToLowerInvariant()
$wrapperLen = (Get-Item -LiteralPath $wrapperPath).Length
Write-Host ("  内层 {0:N0} B / 外层 {1:N0} B" -f $exe.Length, $wrapperLen)

$info = @{
    Kind = 'wrapper'; Name = $wrapperName; Size = $wrapperLen; Sha256 = $wrapperSha
    Urls = @('http://127.0.0.1:1/unused'); InnerName = $setupName
    InnerSize = $exe.Length; InnerSha256 = $setupSha
}
Assert (Test-UpdateAssetInfo $info 'wrapper') '合法 wrapper 资产通过结构校验' '合法 wrapper 被误拒'
$info2 = New-UpdateAssetInfo $info 'wrapper'
Assert ($info2 -and $info2.InnerSha256 -eq $setupSha -and $info2.Urls.Count -eq 1) '资产信息归一化正确' '资产信息归一化失败'

$badHash = @{}; foreach ($k in $info.Keys) { $badHash[$k] = $info[$k] }
$badHash['innerSha256'] = '0' * 64
Assert (-not (Test-UpdateAssetInfo $badHash 'wrapper')) '内层哈希非法被拒绝' '内层哈希非法却放行'
$badName = @{}; foreach ($k in $info.Keys) { $badName[$k] = $info[$k] }
$badName['innerName'] = '../evil.exe'
Assert (-not (Test-UpdateAssetInfo $badName 'wrapper')) '内层路径穿越被拒绝' '路径穿越未被拒绝'

# ---------- 2. 解包 + 内层哈希回读 ----------
$dest = Join-Path (Get-UpdateUnpackRoot) ('unpack-b140-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$innerPath = Expand-UpdateWrapper $wrapperPath $dest $info2
Assert ($innerPath -and (Test-Path -LiteralPath $innerPath)) 'wrapper 解包成功' 'wrapper 解包失败'
Assert ((Get-FileHash -LiteralPath $innerPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $setupSha) '解出的内层 exe 哈希正确' '解出的 exe 与清单不符'

$badExe = New-Object byte[] 2048
(New-Object System.Random(7)).NextBytes($badExe)
$badZip = Join-Path $work 'bad-inner.zip'
New-Wrapper $badZip $setupName $badExe
$err = ''
try { $null = Expand-UpdateWrapper $badZip $dest $info2 } catch { $err = $_.Exception.Message }
Assert ($err -eq 'INNER_HASH') "内层哈希不符抛 INNER_HASH（$err）" "内层哈希不符没有拦住：$err"

$outside = Join-Path $work 'unpack-outside'
$err2 = ''
try { $null = Expand-UpdateWrapper $wrapperPath $outside $info2 } catch { $err2 = $_.Exception.Message }
Assert ($err2 -eq 'UNPACK_PATH') '拒绝解包到更新目录之外' '解包目录没有限制'
Remove-UpdateUnpackDir $dest

# ---------- 3. 端到端：setup 全源 404 → 自动改下 wrapper → 解压 → ready ----------
$serverCode = @'
param([hashtable]$State, [byte[]]$WrapperBytes)
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$State.port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
$State.ready = $true
while (-not $State.stop) {
    try { if (-not $listener.Pending()) { Start-Sleep -Milliseconds 30; continue } } catch { break }
    try { $client = $listener.AcceptTcpClient() } catch { break }
    try {
        $ns = $client.GetStream()
        $ns.ReadTimeout = 5000
        $buf = New-Object byte[] 8192
        $read = $ns.Read($buf, 0, $buf.Length)
        $line = ([Text.Encoding]::ASCII.GetString($buf, 0, $read) -split "`r?`n")[0]
        if ($line -match 'setup') {
            $body = [Text.Encoding]::ASCII.GetBytes('not found')
            $h = "HTTP/1.1 404 Not Found`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
        } else {
            $body = $WrapperBytes
            $h = "HTTP/1.1 200 OK`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
        }
        $hb = [Text.Encoding]::ASCII.GetBytes($h)
        $ns.Write($hb, 0, $hb.Length)
        $ns.Write($body, 0, $body.Length)
        $ns.Flush()
        $State.hits = [int]$State.hits + 1
    } catch { } finally { try { $client.Close() } catch { } }
}
try { $listener.Stop() } catch { }
'@
$state = @{ ready = $false; stop = $false; port = 0; hits = 0 }
$sps = [PowerShell]::Create()
[void]$sps.AddScript($serverCode).AddArgument($state).AddArgument([byte[]]([IO.File]::ReadAllBytes($wrapperPath)))
$sh = $sps.BeginInvoke()
for ($i = 0; $i -lt 100 -and -not $state.ready; $i++) { Start-Sleep -Milliseconds 30 }
Assert $state.ready '本地 mock 源就绪' 'mock 源启动失败'
if (-not $state.ready) { exit 1 }

# 宿主依赖打桩：只测下载/回退链路，不启动 WebView2 宿主。
$script:Logs = New-Object System.Collections.ArrayList
$script:Msgs = New-Object System.Collections.ArrayList
function Write-AppLog { param([string]$m, [string]$cls = '') [void]$script:Logs.Add($m) }
function Send-ToUi { param($msg) [void]$script:Msgs.Add($msg) }
function Save-Config { }
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $repoRoot 'src\app\06-NetProxy.ps1')
$script:NetProxyHelper = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\app\06-NetProxy.ps1'))
. (Join-Path $repoRoot 'src\app\70-Updates.ps1')
$script:AppVersion = '2.1.8'
$script:Cfg = @{}
$script:Root = $work
$script:UpdateAllowedHosts = @('127.0.0.1')
function Test-UpdateHost { param([string]$Url) try { return (([Uri]$Url).Host -eq '127.0.0.1') } catch { return $false } }

$setupUrl = 'http://127.0.0.1:' + [int]$state.port + '/setup.exe'
$wrapperUrl = 'http://127.0.0.1:' + [int]$state.port + '/wrapper.zip'
$fb = New-UpdateAssetInfo @{
    Kind = 'wrapper'; Name = $wrapperName; Size = $wrapperLen; Sha256 = $wrapperSha
    Urls = @($wrapperUrl); InnerName = $setupName; InnerSize = $exe.Length; InnerSha256 = $setupSha
} 'wrapper'

Start-UpdateDownload -Name $setupName -Urls @($setupUrl) -Sha256 $setupSha -Size ([long]$exe.Length) -Kind 'setup' -Fallback $fb
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline) {
    try { Invoke-UpdateTick } catch { }
    if ($script:UpdateState -in @('ready', 'error') -and -not $script:UpdateCtx) { break }
    Start-Sleep -Milliseconds 40
}
Assert ($script:UpdateState -eq 'ready') "回退后进入 ready（state=$($script:UpdateState)）" "回退没有完成：state=$($script:UpdateState)"
$ready = @($script:Msgs | Where-Object { $_.type -eq 'update' -and $_.state -eq 'ready' })[0]
if ($ready) {
    Assert ($ready.assetKind -eq 'wrapper') 'ready 消息标记为 wrapper' 'ready 消息没有标记 wrapper'
    Assert ($ready.name -eq $setupName -and $ready.sha256 -eq $setupSha) 'ready 指向内层 exe 与其哈希' 'ready 仍指向外层 zip'
    Assert (Test-Path -LiteralPath ([string]$ready.path)) '内层 exe 已落盘' '内层 exe 不存在'
    $unpack = Get-UpdateUnpackDirForPath ([string]$ready.path)
    Assert ($unpack -and (Test-Path -LiteralPath $unpack)) '解包目录位于受控位置' '找不到解包目录'
    Remove-UpdateUnpackDir $unpack
    Assert (-not (Test-Path -LiteralPath $unpack)) '清理函数可删除解包目录' '解包目录没删掉'
} else {
    Bad '没有收到 ready 消息'
}
Assert (@($script:Logs | Where-Object { $_ -match 'setup 资产全源失败' }).Count -ge 1) '日志记录了回退原因' '日志缺回退记录'

# ---------- 4. 静态接线守卫 ----------
$entry = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\PerfCapture.ps1'))
$hostSrc = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\app\70-Updates.ps1'))
$packSrc = [IO.File]::ReadAllText((Join-Path $repoRoot 'build\pack.ps1'))
$pushSrc = [IO.File]::ReadAllText((Join-Path $repoRoot 'build\push-updates.ps1'))
Assert ($entry -match '68-UpdateWrapper\.ps1') '入口加载了 wrapper 助手' '入口没加载 wrapper 助手'
Assert ($hostSrc -match 'fallback = \$fallbackInfo') '清单检查登记了回退资产' '检查更新没登记回退'
Assert ($hostSrc -match 'Expand-UpdateWrapper -ZipPath') '下载完成后解压并校验内层' '没有解压校验'
Assert ($hostSrc -match 'Schedule-UpdateUnpackCleanup') '安装后延迟清理解包目录' '没有清理时机'
Assert ($packSrc -match 'PerfCapture-Update-\$Version\.zip') '打包侧生成 wrapper 资产' '打包侧没生成 wrapper'
Assert ($packSrc -match 'innerSha256') '清单记录了内层哈希' '清单缺内层哈希'
Assert ($pushSrc -match 'PerfCapture-Update-\$version\.zip') '推送脚本同步 wrapper' '推送脚本漏掉 wrapper'

Write-Host ''
if ($fail -eq 0) { Write-Host '== B140 全部通过 ==' -ForegroundColor Green }
else { Write-Host "== B140 失败 $fail 项 ==" -ForegroundColor Red }
try { $state.stop = $true } catch { }
try { $sps.Stop() } catch { }
try { $sps.Dispose() } catch { }
try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
if ($fail) { exit 1 }
