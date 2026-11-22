# 06-NetProxy.ps1 — M1：网络请求显式使用系统代理，并保留直连回退
# 本文件同时被宿主 dot-source、并以源码字符串注入两个后台 runspace：
#   宿主：Get-NetProxyDescriptor / Set-RequestProxy 等函数直接可用；
#   worker：. ([scriptblock]::Create($NetProxyHelper)) 后得到同一套实现，避免两处维护。
# 为什么显式赋值：.NET 的默认代理行为随运行时/配置变化，出问题既看不到走了哪条代理，
# 也无法在代理异常时可靠地直连重试。这里把「代理是什么、是否生效、失败怎么退」写死成一条路径。

function Get-NetProxyDescriptor {
    param([string]$Url = 'https://github.com/')

    $result = @{ mode = 'none'; label = 'none'; endpoint = ''; source = 'none'; webProxy = $null; active = $false }
    try { $result.webProxy = [System.Net.WebRequest]::GetSystemWebProxy() } catch { }

    $uri = $null
    try { $uri = [Uri]$Url } catch { }
    $endpoint = ''
    if ($result.webProxy -and $uri) {
        try {
            $bypass = $result.webProxy.IsBypassed($uri)
            $ep = $result.webProxy.GetProxy($uri)
            if (-not $bypass -and $ep -and $ep.Scheme -eq 'http' -and $ep.Host -and $ep.Host -ne $uri.Host) {
                $endpoint = $ep.Host + ':' + $ep.Port
            }
        } catch { }
    }

    # 区分「自动配置脚本（PAC）」与「手动填的代理」：诊断里要能一眼看出用户开的是哪一种。
    # 注册表只是来源提示；真正用不用代理以上面 GetProxy() 的结果为准。
    $source = 'none'
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Internet Settings')
        if ($key) {
            $autoCfg = [string]$key.GetValue('AutoConfigURL', '')
            $enabled = 0
            [void][int]::TryParse([string]$key.GetValue('ProxyEnable', '0'), [ref]$enabled)
            $server = [string]$key.GetValue('ProxyServer', '')
            $key.Close()
            if ($autoCfg) { $source = 'auto' }
            elseif ($enabled -eq 1 -and $server) { $source = 'explicit' }
        }
    } catch { }

    $mode = if ($endpoint) { if ($source -eq 'auto') { 'auto' } else { 'proxy' } } elseif ($source -eq 'auto') { 'auto' } else { 'none' }
    $label = if ($endpoint) { $mode + '(' + $endpoint + ')' } else { $mode }
    $result.mode = $mode
    $result.label = $label
    $result.endpoint = $endpoint
    $result.source = $source
    $result.active = [bool]$endpoint
    return $result
}

function Get-DirectProxyInfo {
    # Proxy = 空 WebProxy 而不是 $null：$null 会让 HttpWebRequest 重新去拿系统代理，
    # 那就不是「直连回退」，而是原地再走一次坏代理。
    return @{ mode = 'none'; label = 'none'; endpoint = ''; source = 'direct'; webProxy = $null; active = $false }
}

function Set-RequestProxy($Request, $ProxyInfo) {
    if ($ProxyInfo -and $ProxyInfo.active -and $ProxyInfo.webProxy) {
        $Request.Proxy = $ProxyInfo.webProxy
    } else {
        $Request.Proxy = New-Object System.Net.WebProxy
    }
    return $Request
}

function New-ProxyHttpClient($ProxyInfo, [int]$TimeoutMs) {
    $handler = New-Object System.Net.Http.HttpClientHandler
    if ($ProxyInfo -and $ProxyInfo.active -and $ProxyInfo.webProxy) {
        $handler.Proxy = $ProxyInfo.webProxy
        $handler.UseProxy = $true
    } else {
        $handler.UseProxy = $false
    }
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMs)
    return $client
}

# 本文件既是宿主组件，也是注入 worker 的源码。宿主 dot-source 时记住自己的源码，
# Start-UpdateCheck / Start-ExtensionProvision 把它当参数带进 runspace，避免两处维护。
if ($PSCommandPath -and [IO.File]::Exists($PSCommandPath)) {
    try { $script:NetProxyHelper = [IO.File]::ReadAllText($PSCommandPath) } catch { }
}
