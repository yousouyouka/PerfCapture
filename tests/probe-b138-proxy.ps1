# B138 M1 系统代理显式化探针：代理助手 / 显式走代理 / 坏代理直连回退 / 诊断记录。
# 不依赖外网：本地 mock HTTP 服务 + 可控的代理描述符注入。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b138-proxy.ps1

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host '== B138 M1 系统代理显式化探针 ==' -ForegroundColor Cyan

# ---------- 0. 助手本体 ----------
$helperPath = Join-Path $root 'src\app\06-NetProxy.ps1'
Assert (Test-Path -LiteralPath $helperPath) '06-NetProxy.ps1 存在' '缺少代理助手文件'
. $helperPath
Assert ([bool](Get-Command Get-NetProxyDescriptor -ErrorAction SilentlyContinue)) '助手函数已加载' '助手函数未加载'
$desc = Get-NetProxyDescriptor 'https://github.com/'
Assert ($desc -and $desc.ContainsKey('mode') -and $desc.ContainsKey('label') -and $desc.webProxy -ne $null) '描述符含 mode/label/webProxy' '描述符结构不完整'
Write-Host ("  当前系统代理识别: mode={0} label={1} source={2}" -f $desc.mode, $desc.label, $desc.source)

$direct = Get-DirectProxyInfo
$req = [System.Net.HttpWebRequest]::Create('http://example.com/file')
[void](Set-RequestProxy $req $direct)
$directUri = $req.Proxy.GetProxy([Uri]'http://example.com/file')
Assert ($directUri.Host -eq 'example.com') '直连模式的 Proxy 不会偷偷回退到系统代理' ('直连被代理劫持: ' + $directUri)

# ---------- 1. 本地 mock 服务：目标返回 DIRECT，代理返回 PROXY ----------
$serverCode = @'
param([hashtable]$State, [string]$Body, [string]$Bind)
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($Bind), 0)
$listener.Start()
$State.port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
$State.ready = $true
$bytes = [System.Text.Encoding]::ASCII.GetBytes($Body)
$head = "HTTP/1.1 200 OK`r`nContent-Type: text/plain`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
$hb = [System.Text.Encoding]::ASCII.GetBytes($head)
while (-not $State.stop) {
    try { if (-not $listener.Pending()) { Start-Sleep -Milliseconds 30; continue } } catch { break }
    try { $client = $listener.AcceptTcpClient() } catch { break }
    try {
        $ns = $client.GetStream()
        $ns.ReadTimeout = 5000
        $buf = New-Object byte[] 8192
        $read = $ns.Read($buf, 0, $buf.Length)
        $State.hits = [int]$State.hits + 1
        $State.lastRequest = ([System.Text.Encoding]::ASCII.GetString($buf, 0, $read) -split "`r`n")[0]
        $ns.Write($hb, 0, $hb.Length)
        $ns.Write($bytes, 0, $bytes.Length)
        $ns.Flush()
    } catch { } finally { try { $client.Close() } catch { } }
}
try { $listener.Stop() } catch { }
'@
function New-Mock([string]$body, [string]$bind = '127.0.0.1') {
    $st = @{ ready = $false; stop = $false; port = 0; hits = 0; lastRequest = '' }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($serverCode).AddArgument($st).AddArgument($body).AddArgument($bind)
    $h = $ps.BeginInvoke()
    $n = 0
    while (-not $st.ready -and $n -lt 100) { Start-Sleep -Milliseconds 30; $n++ }
    return @{ state = $st; ps = $ps; handle = $h }
}
function Stop-Mock($m) { try { $m.state.stop = $true } catch { }; try { $m.ps.Stop() } catch { }; try { $m.ps.Dispose() } catch { } }

$target = New-Mock 'DIRECT'
# 代理放 127.0.0.2（同属回环段但不同主机）：避免 .NET 把「同主机不同端口」当成直连绕过。
$proxy  = New-Mock 'PROXY' '127.0.0.2'
Assert ($target.state.ready -and $proxy.state.ready) '本地目标 / 代理服务就绪' 'mock 服务启动失败'
$targetUrl = 'http://127.0.0.1:' + [int]$target.state.port + '/file.bin'
$targetUrl2 = 'http://127.0.0.1:' + [int]$target.state.port + '/file2.bin'

function Read-Url([string]$url, $proxyInfo) {
    $r = [System.Net.HttpWebRequest]::Create($url)
    [void](Set-RequestProxy $r $proxyInfo)
    $r.Timeout = 5000
    $r.ReadWriteTimeout = 5000
    $resp = $r.GetResponse()
    try {
        $sr = New-Object IO.StreamReader($resp.GetResponseStream())
        return $sr.ReadToEnd()
    } finally { try { $resp.Close() } catch { } }
}

# ---------- 2. 显式代理赋值真的生效 ----------
$fake = Get-DirectProxyInfo
$fake.mode = 'proxy'; $fake.active = $true
$fake.endpoint = '127.0.0.2:' + [int]$proxy.state.port
$fake.label = 'test(' + $fake.endpoint + ')'
$fake.webProxy = New-Object System.Net.WebProxy('http://' + $fake.endpoint)
# 用非本机域名测代理：本机地址在部分 .NET 配置下会被 WebProxy 自动绕过，不能代表真实走代理。
$proxyTestUrl = 'http://perf.test/file.bin'
$viaProxy = Read-Url $proxyTestUrl $fake
Assert ($viaProxy -eq 'PROXY') '请求确实经过显式代理（拿到 PROXY 响应）' ('未走代理: ' + $viaProxy)
Assert ([int]$proxy.state.hits -ge 1 -and [string]$proxy.state.lastRequest -match '^GET http://') '代理收到绝对 URL 的标准代理请求' '代理未收到请求'
$viaDirect = Read-Url $targetUrl $direct
Assert ($viaDirect -eq 'DIRECT') '直连模式绕过代理（拿到 DIRECT 响应）' ('直连异常: ' + $viaDirect)

# ---------- 3. 更新下载 worker：坏代理 → 直连回退成功 ----------
$src = [IO.File]::ReadAllText((Join-Path $root 'src\app\70-Updates.ps1'))
$i = $src.IndexOf("`$script:UpdateDownloadScript = @'")
$s0 = $src.IndexOf("`n", $i) + 1
$e0 = $src.IndexOf("`n'@", $s0)
$runner = [scriptblock]::Create($src.Substring($s0, $e0 - $s0))
$helperSrc = [IO.File]::ReadAllText($helperPath)
# 强制型代理：.NET 对 127.0.0.1 目标会自动绕过普通 WebProxy，
# 这里用一个永远不绕过的 IWebProxy 模拟「系统代理把本机地址也接管了」的场景。
Add-Type -TypeDefinition @'
using System;
using System.Net;
public class PerfCaptureForcedProxy : IWebProxy {
    public Uri Address { get; set; }
    public ICredentials Credentials { get; set; }
    public Uri GetProxy(Uri destination) { return Address; }
    public bool IsBypassed(Uri host) { return false; }
}
'@
# 注入一个「系统代理指向坏端口」的助手：不改注册表，也不影响其它进程。
$override = @"
`nfunction Get-NetProxyDescriptor {
    param([string]`$Url)
    `$wp = New-Object PerfCaptureForcedProxy
    `$wp.Address = [Uri]'http://bad.proxy.invalid:9'
    return @{ mode='proxy'; label='proxy(bad.proxy.invalid:9)'; endpoint='bad.proxy.invalid:9'; source='explicit'; webProxy=`$wp; active=`$true }
}
"@
$injected = $helperSrc + $override
$work = Join-Path $env:TEMP ('PerfCapture-B138-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$payload = [Text.Encoding]::ASCII.GetBytes('DIRECT')
$sha = ([BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($payload))).Replace('-', '').ToLowerInvariant()
$cts = New-Object System.Threading.CancellationTokenSource
$out = Join-Path $work 'setup.exe'
# 单源跳过探测阶段，直接验证「代理下载失败 → 同一源直连重试」这条关键回退路径。
$res = @(& $runner -Urls @($targetUrl) -OutPath $out -PartPath ($out + '.part') -MaxBytes 1048576 `
    -ExpectedSize $payload.Length -AllowedHosts @('127.0.0.1') -Token $cts.Token `
    -ProbeMs 1500 -StallSec 10 -NetProxyHelper $injected)[0]
Assert ($res.ok -eq $true) ('坏代理下直连回退下载成功（err=' + [string]$res.err + '）') ('回退失败: ' + [string]$res.err)
Assert ([string]$res.sha256 -eq $sha) '回退下载的内容哈希正确' ('哈希不符: ' + $res.sha256)
$log = @($res.log) -join ' | '
Assert ($log -match 'proxy proxy\(bad\.proxy\.invalid:9\)') '日志记录了代理状态' ('日志缺代理状态: ' + $log)
Assert (@($res.log | Where-Object { $_ -match '^attempt ' }).Count -ge 1) '下载阶段逐次记录了代理尝试' ('日志缺尝试记录: ' + $log)
Assert ($src -match 'retry probe direct' -and $src -match 'Set-RequestProxy.*\$pi') '下载引擎保留探测与逐次请求的直连回退分支' '下载引擎缺直连回退分支'

# ---------- 4. 两个 worker 都接入了同一助手（静态守卫，防未来改动漏接） ----------
foreach ($f in 'src\app\70-Updates.ps1', 'src\app\85-ExtensionProvision.ps1') {
    $text = [IO.File]::ReadAllText((Join-Path $root $f))
    Assert ($text -match 'Set-RequestProxy' -and $text -match 'New-ProxyHttpClient' -and $text -match 'retry probe direct') "$f 已接入代理助手与直连回退" "$f 缺代理助手调用"
}
$entry = [IO.File]::ReadAllText((Join-Path $root 'src\PerfCapture.ps1'))
Assert ($entry -match "'06-NetProxy\.ps1'") '入口已加载 06-NetProxy.ps1' '入口未加载代理助手'

Stop-Mock $target
Stop-Mock $proxy
Write-Host ("== B138 完成：{0} 项失败 ==" -f $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
if ($fail) { exit 1 }
