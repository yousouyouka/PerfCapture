# 检查更新：多源清单 → RSA 验签 → 版本比较 → 下载资产（边下边算 SHA-256）→ 本地校验
#
# 安全模型（四道闸，缺一不可）：
#   1) 清单必须用内置公钥的 RSA-2048/SHA-256 验签 —— 镜像/代理被劫持也只能拿到验不过的垃圾；
#   2) 安装包按**已验签清单**里的 sha256 + size 本地比对，不符立即删文件；
#   3) 只允许白名单主机；清单 ≤256 KB、资产 ≤60 MB；
#   4) 从不自动安装/执行：下载完只给"打开文件夹/运行安装包"，安装由用户点。
#
# 自动检查策略（用户 2026-11-15 定）：**每次启动最多检查一次**；
#   没发现新版本就停止本次会话的自动检查（下次启动恢复），发现新版本提示后同样不重复检查。
# Windows PowerShell 5.1 默认不加载 System.Net.Http：不显式加载的话，runspace 里
# New-Object System.Net.Http.HttpClient 会拿到 $null（报"不能对 Null 值表达式调用方法"）。
try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { Write-AppLog ('加载 System.Net.Http 失败: ' + $_.Exception.Message) 'WARN' }


$script:UpdatePublicKeyXml = '<RSAKeyValue><Modulus>v74SUV20i/kw4EIzvlWr+OL5miN6dL8rvH9n0tvX9huqDIK8maFlIMOu3ROztgxzCBQhfW0XBE6SWYrwbJMA7s3YSPC+Ko4hBS0VwbjiBdZ+Dr2uZX6APNCLv7jKME0KeBVbnnRAdchISTHGdcZ1aiEjIfWrhvOMd5FesySJ5sUCZe7BlGPHlpJ2ffx/qJSKU7d/uSIibnUwBnQPKC/0Db2vPemb3Hu0qe/pLRwpXWNPHaxoyZfATauChLNSCWAbs0htQ0M020FmDFEzHkTkMKm8xNO7SGPDL6cgjSho4uV4DqzwCekbaPcwNdPSeLmV9zUMRGcL2OeZlTHEhAwRKQ==</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'

# 只允许这些主机（拒绝重定向到别处也由这层兜底）
$script:UpdateAllowedHosts = @(
    'cdn.jsdelivr.net', 'fastly.jsdelivr.net',
    'raw.githubusercontent.com', 'api.github.com', 'objects.githubusercontent.com', 'github.com',
    'ghproxy.net', 'gitee.com'
)

# 清单源顺序：raw / api 直连仓库、内容即刻更新；jsDelivr 排最后 —— 2.0.21 发布后实测它
# 长时间（数小时以上）仍返回 2.0.10 的旧清单，排第一会把「有新版本」误判成「已是最新」。
# 注意：顺序如今只影响同版本并列时的取舍与日志，真正选中哪一份由 version/serial 最大者决定
# （见下方 UpdateFetchScript 的多源策略）。
$script:UpdateManifestSources = @(
    'https://raw.githubusercontent.com/yousouyouka/PerfCapture/main/updates/latest.json',
    'https://api.github.com/repos/yousouyouka/PerfCapture/contents/updates/latest.json',
    'https://cdn.jsdelivr.net/gh/yousouyouka/PerfCapture@main/updates/latest.json'
)

$script:UpdateMaxManifestBytes = 262144
$script:UpdateMaxAssetBytes = 62914560
$script:UpdateAutoCheckDelayMs = 12000

$script:UpdateState = 'idle'        # idle|checking|latest|available|downloading|verifying|ready|error
# 检查失败自动重试：等待 15 秒再查，最多 3 次（失败多半是断网/镜像抖动，重启程序太粗暴）
$script:UpdateRetryCount = 0
$script:UpdateRetryTimer = $null
$script:UpdateExitTimer = $null
$script:UpdateExitRequested = $false
$script:UpdateAutoCheckDone = $false
$script:UpdateCtx = $null
$script:UpdateTimer = $null
$script:UpdateDelayTimer = $null   # 启动后自动检查的延时计时器

# ---------- 工具 ----------
function Compare-AppVersion {
    param([string]$A, [string]$B)
    $sa = @([string]$A -split '\.' | ForEach-Object { $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 } })
    $sb = @([string]$B -split '\.' | ForEach-Object { $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 } })
    $len = [Math]::Max($sa.Count, $sb.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $x = if ($i -lt $sa.Count) { $sa[$i] } else { 0 }
        $y = if ($i -lt $sb.Count) { $sb[$i] } else { 0 }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}

function Test-UpdateHost {
    param([string]$Url)
    try {
        $u = [Uri]$Url
        if ($u.Scheme -ne 'https') { return $false }
        return ($script:UpdateAllowedHosts -contains $u.Host.ToLowerInvariant())
    } catch { return $false }
}

function Test-UpdateSignature {
    param([byte[]]$Bytes, [byte[]]$Signature)
    try {
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $rsa.PersistKeyInCsp = $false
        $rsa.FromXmlString($script:UpdatePublicKeyXml)
        $hash = [System.Security.Cryptography.SHA256]::Create()
        $ok = $rsa.VerifyData($Bytes, $hash, $Signature)
        $hash.Dispose(); $rsa.Dispose()
        return $ok
    } catch {
        Write-AppLog ('验签异常: ' + $_.Exception.Message) 'WARN'
        return $false
    }
}

function Send-UpdateState {
    param([hashtable]$Payload)
    $msg = @{ type = 'update'; current = $script:AppVersion }
    foreach ($k in $Payload.Keys) { $msg[$k] = $Payload[$k] }
    Send-ToUi $msg
}

function Stop-UpdateTimer {
    if ($script:UpdateTimer) {
        try { $script:UpdateTimer.Stop(); $script:UpdateTimer.Dispose() } catch { }
        $script:UpdateTimer = $null
    }
}

# ---------- 后台线程里跑的脚本（runspace，不阻塞 UI 线程） ----------
$script:UpdateFetchScript = @'
param($ManifestUrls, $TimeoutSec, $PublicKeyXml, $AllowedHosts, [string]$NetProxyHelper)
if ($NetProxyHelper) { . ([scriptblock]::Create($NetProxyHelper)) }
# M1：显式使用系统代理；探测失败时把 proxy=... 一并带回去，日志里能看出走了哪条路。
$proxyInfo = Get-NetProxyDescriptor ([string]$ManifestUrls[0])
# 多源策略（2.0.22 起）：
#   1) 所有源**同时**取清单与签名，互不等待，总耗时约等于最慢的那个（串行最坏要 3 倍超时）；
#   2) 每个源各自独立验签，验签不过的直接丢弃 —— 镜像出现「新清单 + 旧签名」错配时不牵连其它源；
#   3) 全部收齐后按 version 取最大、同版本再比 serial。某个镜像缓存滞后（jsDelivr 实测长期吐 2.0.10）
#      不会再让检查更新误判成「已是最新」；
#   4) 源顺序只影响同版本并列时的取舍与日志，不再决定结果。
function Test-Host($uri) {
    try { return ($AllowedHosts -contains $uri.Host.ToLowerInvariant()) } catch { return $false }
}
function Test-Sig([byte[]]$Data, [byte[]]$Sig) {
    try {
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $rsa.PersistKeyInCsp = $false
        $rsa.FromXmlString($PublicKeyXml)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $ok = $rsa.VerifyData($Data, $sha, $Sig)
        $sha.Dispose(); $rsa.Dispose()
        return $ok
    } catch { return $false }
}
function Compare-Ver([string]$A, [string]$B) {
    $sa = @([string]$A -split '\.' | ForEach-Object { $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 } })
    $sb = @([string]$B -split '\.' | ForEach-Object { $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 } })
    $len = [Math]::Max($sa.Count, $sb.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $x = if ($i -lt $sa.Count) { $sa[$i] } else { 0 }
        $y = if ($i -lt $sb.Count) { $sb[$i] } else { 0 }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}
$errs = @('proxy=' + $proxyInfo.label)
$sigFail = $false
$cands = @()
$http = New-ProxyHttpClient $proxyInfo ([int]($TimeoutSec * 1000))
try { $http.DefaultRequestHeaders.UserAgent.ParseAdd('PerfCapture/1.4') } catch {}
try { $http.DefaultRequestHeaders.Add('Accept', 'application/vnd.github.raw, application/json, */*') } catch {}
# 先把所有请求一次性发出去（清单与签名各一个 Task），再逐个收结果
$pending = @()
foreach ($u in $ManifestUrls) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $mt = $http.GetAsync($u)
        $st = $http.GetAsync($u + '.sig')
        $pending += [pscustomobject]@{ Url = $u; MT = $mt; ST = $st; Sw = $sw }
    } catch {
        $errs += ('{0} 请求未发出: {1}' -f $u, (($_.Exception.Message -split '\r?\n')[0]))
    }
}
foreach ($p in $pending) {
    $u = $p.Url
    try {
        $r = $p.MT.GetAwaiter().GetResult()
        if (-not $r.IsSuccessStatusCode) { $errs += ('{0} HTTP {1}' -f $u, [int]$r.StatusCode); continue }
        # 白名单要按**最终**地址判：允许自动重定向，但重定向到白名单外一律拒绝
        if (-not (Test-Host $r.RequestMessage.RequestUri)) {
            $errs += ('{0} 被重定向到白名单外主机 {1}' -f $u, $r.RequestMessage.RequestUri.Host); continue
        }
        $declared = $r.Content.Headers.ContentLength
        if ($declared -and $declared -gt 262144) { $errs += ('{0} 过大 {1} 字节' -f $u, $declared); continue }
        $mb = $r.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        if ($mb.Length -lt 2 -or $mb.Length -gt 262144) { $errs += ('{0} 大小异常 {1}' -f $u, $mb.Length); continue }

        $sr = $p.ST.GetAwaiter().GetResult()
        if (-not $sr.IsSuccessStatusCode) { $errs += ('{0}.sig HTTP {1}' -f $u, [int]$sr.StatusCode); continue }
        if (-not (Test-Host $sr.RequestMessage.RequestUri)) { $errs += ('{0}.sig 被重定向到白名单外主机' -f $u); continue }
        $sb = $sr.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $sigText = ([Text.Encoding]::ASCII.GetString($sb)) -replace '\s', ''
        $sigRaw = $null
        try { $sigRaw = [Convert]::FromBase64String($sigText) } catch { }
        if (-not $sigRaw -or $sigRaw.Length -ne 256) { $errs += ('{0} 签名不可用（{1} 字符）' -f $u, $sigText.Length); continue }

        if (-not (Test-Sig $mb $sigRaw)) {
            $sigFail = $true
            $errs += ('{0} 签名不符（镜像清单与签名不同步？）' -f $u)
            continue
        }
        # 验签通过还不够：要能读出 version 才能比较新旧，读不出的一律不当候选
        $ver = ''
        $ser = [long]0
        try {
            $jk = ([Text.Encoding]::UTF8.GetString($mb)) | ConvertFrom-Json
            $ver = [string]$jk.version
            if ($jk.serial) { $ser = [long]$jk.serial }
        } catch { }
        if (-not $ver) { $errs += ('{0} 清单缺少 version 字段' -f $u); continue }
        $cands += [pscustomobject]@{
            Url = $u; Ms = $p.Sw.ElapsedMilliseconds; Version = $ver; Serial = $ser
            Manifest = [Convert]::ToBase64String($mb); Sig = [Convert]::ToBase64String($sigRaw)
        }
    } catch {
        $errs += ('{0} 失败: {1}' -f $u, (($_.Exception.Message -split '\r?\n')[0]))
    } finally {
        try { $p.Sw.Stop() } catch { }
    }
}
if ($cands.Count -gt 0) {
    $best = $cands[0]
    foreach ($c in $cands) {
        $cmp = Compare-Ver $c.Version $best.Version
        if ($cmp -gt 0 -or ($cmp -eq 0 -and $c.Serial -gt $best.Serial)) { $best = $c }
    }
    $seen = @($cands | ForEach-Object { [pscustomobject]@{ url = $_.Url; version = $_.Version; serial = $_.Serial } })
    return [pscustomobject]@{
        ok = $true; url = $best.Url; ms = $best.Ms
        manifest = $best.Manifest; sig = $best.Sig; sigFail = $false; errors = $errs
        version = $best.Version; serial = $best.Serial; candidates = $seen; proxy = $proxyInfo.label
    }
}
return [pscustomobject]@{
    ok = $false; url = ''; ms = 0; manifest = ''; sig = ''; sigFail = $sigFail; errors = $errs
    version = ''; serial = [long]0; candidates = @(); proxy = $proxyInfo.label
}
'@

$script:UpdateDownloadScript = @'
param($Urls, $OutPath, $PartPath, $MaxBytes, $ExpectedSize, $AllowedHosts, $Token, $ProbeMs, $StallSec, [string]$NetProxyHelper)
if ($NetProxyHelper) { . ([scriptblock]::Create($NetProxyHelper)) }
$proxyInfo = Get-NetProxyDescriptor ([string]@($Urls)[0])
$directInfo = Get-DirectProxyInfo
# 2.1.8 下载引擎：探测排序 → 多源接力（.part 续传）→ 整体 SHA-256。
# 与扩展供应层同一套策略：先并发试首字节，慢源/死源不再各消耗一次完整超时；
# 换源不丢进度（.part 保留，新源用 Range 续），最终仍以清单里的整包哈希为准。
function Test-Host($uri) {
    try { return ($AllowedHosts -contains $uri.Host.ToLowerInvariant()) } catch { return $false }
}
$log = New-Object System.Collections.Generic.List[string]
$log.Add('proxy ' + $proxyInfo.label)
function Fail([string]$code, [bool]$keepPart = $false) {
    # 全源失败时保留 .part：下次重试/重启后能接着下（大小与整包哈希仍会兜底校验）。
    if (-not $keepPart) {
        try { if ($PartPath -and (Test-Path -LiteralPath $PartPath)) { Remove-Item -LiteralPath $PartPath -Force -ErrorAction SilentlyContinue } } catch { }
    }
    return [pscustomobject]@{ ok = $false; err = $code; sha256 = ''; size = 0; url = ''; proxy = $proxyInfo.label; log = @($log) }
}
$ordered = @($Urls | Where-Object { $_ })

# ---------- 1. 探测：并发 Range 0-0，按首字节耗时排队 ----------
if ($ordered.Count -gt 1) {
    $http = $null
    $cts = $null
    try {
        try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { throw 'nohttp' }
        $http = New-ProxyHttpClient $proxyInfo ([int]$ProbeMs + 2000)
        try { $http.DefaultRequestHeaders.UserAgent.ParseAdd('PerfCapture/2.1') } catch { }
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter([int]$ProbeMs)
        $jobs = @()
        foreach ($u in $ordered) {
            $w = [Diagnostics.Stopwatch]::StartNew()
            $t = $null
            try {
                $rq = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, [string]$u)
                $rq.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue(0, 0)
                $t = $http.SendAsync($rq, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token)
            } catch { }
            $jobs += [pscustomobject]@{ Url = [string]$u; Task = $t; Sw = $w; Ms = -1; Ok = $false }
        }
        $tasks = @($jobs | Where-Object { $_.Task } | ForEach-Object { $_.Task })
        if ($tasks.Count) { try { [void][System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]$tasks, [int]$ProbeMs) } catch { } }
        foreach ($j in $jobs) {
            if ($j.Task) {
                try {
                    if ($j.Task.IsCompleted) {
                        $rs = $j.Task.GetAwaiter().GetResult()
                        if ($rs -and $rs.IsSuccessStatusCode) { $j.Ok = $true; $j.Ms = [int]$j.Sw.ElapsedMilliseconds }
                        if ($rs) { $rs.Dispose() }
                    }
                } catch { }
            }
            try { $j.Sw.Stop() } catch { }
            $log.Add('probe ' + $j.Url + ' -> ' + $(if ($j.Ok) { [string]$j.Ms + 'ms' } else { 'unreachable' }))
        }
        $good = @($jobs | Where-Object { $_.Ok } | Sort-Object -Property Ms | ForEach-Object { $_.Url })
        # M1 直连回退：代理下所有源都探不通时，用直连再探一次（只多一次探测预算）。
        if (-not $good.Count -and $proxyInfo.active) {
            $log.Add('proxy unreachable -> retry probe direct')
            $dhttp = $null; $dcts = $null
            try {
                $dhttp = New-ProxyHttpClient $directInfo ([int]$ProbeMs + 2000)
                $dcts = New-Object System.Threading.CancellationTokenSource
                $dcts.CancelAfter([int]$ProbeMs)
                foreach ($j in $jobs) {
                    $t = $null
                    try {
                        $rq = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $j.Url)
                        $rq.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue(0, 0)
                        $t = $dhttp.SendAsync($rq, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $dcts.Token)
                        if ($t.IsCompleted) {
                            $rs = $t.GetAwaiter().GetResult()
                            if ($rs -and $rs.IsSuccessStatusCode) { $j.Ok = $true; $j.Ms = [int]$j.Sw.ElapsedMilliseconds }
                            if ($rs) { $rs.Dispose() }
                        }
                    } catch { }
                    $log.Add('direct ' + $j.Url + ' -> ' + $(if ($j.Ok) { [string]$j.Ms + 'ms' } else { 'unreachable' }))
                }
                $good = @($jobs | Where-Object { $_.Ok } | Sort-Object -Property Ms | ForEach-Object { $_.Url })
            } catch { } finally {
                try { if ($dcts) { $dcts.Dispose() } } catch { }
                try { if ($dhttp) { $dhttp.Dispose() } } catch { }
            }
        }
        $bad = @($jobs | Where-Object { -not $_.Ok } | ForEach-Object { $_.Url })
        if ($good.Count) { $ordered = @($good + $bad) }
    } catch {
    } finally {
        try { if ($cts) { $cts.Dispose() } } catch { }
        try { if ($http) { $http.Dispose() } } catch { }
    }
}

# ---------- 2. 多源接力：续传写入 .part，失败换源继续 ----------
$ok = $false
$usedUrl = ''
# M1：代理模式下一个源失败后再用直连试一次；直连模式只试一次。展平成一张尝试表，
# 原有的「成功就 break、失败换下一源」语义不变，.part 仍跨尝试保留。
$attempts = @()
foreach ($u in $ordered) {
    $attempts += [pscustomobject]@{ Url = $u; Proxy = $proxyInfo }
    if ($proxyInfo.active) { $attempts += [pscustomobject]@{ Url = $u; Proxy = $directInfo } }
}
foreach ($a in $attempts) {
    $u = $a.Url
    $pi = $a.Proxy
    $log.Add('attempt ' + $u + ' via ' + $pi.label)
    if ($Token -and $Token.IsCancellationRequested) { return (Fail 'CANCELLED') }
    $existing = 0
    try { if (Test-Path -LiteralPath $PartPath) { $existing = [int64](Get-Item -LiteralPath $PartPath).Length } } catch { $existing = 0 }
    if ($ExpectedSize -gt 0 -and $existing -ge $ExpectedSize) { break }
    $req = [System.Net.HttpWebRequest]::Create([string]$u)
    [void](Set-RequestProxy $req $pi)
    $req.Method = 'GET'
    $req.AllowAutoRedirect = $true
    $req.UserAgent = 'PerfCapture/2.1'
    $req.Timeout = 20000
    $req.ReadWriteTimeout = [int]([math]::Max(5, [int]$StallSec) * 1000)
    if ($existing -gt 0) { [void]$req.AddRange([int64]$existing) }
    $resp = $null
    try { $resp = $req.GetResponse() }
    catch [System.Net.WebException] {
        $st = 0
        try { if ($_.Exception.Response) { $st = [int]$_.Exception.Response.StatusCode } } catch { }
        if ($st -eq 416) { try { Remove-Item -LiteralPath $PartPath -Force -ErrorAction SilentlyContinue } catch { } }
        $log.Add($u + ' -> ' + $st + ' / connect-or-stall')
        continue
    } catch {
        $log.Add($u + ' -> ' + (($_.Exception.Message -split "`r?`n")[0]))
        continue
    }
    $fs = $null
    $stream = $null
    try {
        if (-not (Test-Host $resp.ResponseUri)) { $log.Add($u + ' -> redirect ' + $resp.ResponseUri.Host); continue }
        $code = [int]$resp.StatusCode
        $append = ($code -eq 206 -and $existing -gt 0)
        if (-not $append) {
            $existing = 0
            try { if (Test-Path -LiteralPath $PartPath) { Remove-Item -LiteralPath $PartPath -Force -ErrorAction SilentlyContinue } } catch { }
        }
        $len = [int64]$resp.ContentLength
        $total = if ($len -ge 0) { $len + $existing } else { [int64]0 }
        if ($ExpectedSize -gt 0 -and $total -gt 0 -and $total -ne $ExpectedSize) {
            $log.Add($u + ' -> size ' + $total + ' != ' + $ExpectedSize); continue
        }
        if ($MaxBytes -gt 0 -and $total -gt $MaxBytes) { return (Fail 'TOO_LARGE') }
        $mode = if ($append) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
        $fs = [IO.File]::Open($PartPath, $mode, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream = $resp.GetResponseStream()
        $buf = New-Object byte[] 65536
        $recv = $existing
        while ($true) {
            if ($Token -and $Token.IsCancellationRequested) { throw 'CANCELLED' }
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $fs.Write($buf, 0, $n)
            $recv += $n
            if ($MaxBytes -gt 0 -and $recv -gt $MaxBytes) { throw 'TOO_LARGE' }
        }
        $fs.Flush()
        $fs.Dispose(); $fs = $null
        $stream.Dispose(); $stream = $null
        $resp.Close()
        $got = [int64]0
        try { $got = (Get-Item -LiteralPath $PartPath).Length } catch { $got = $recv }
        if ($ExpectedSize -gt 0 -and $got -ne $ExpectedSize) {
            $log.Add($u + ' -> incomplete ' + $got + '/' + $ExpectedSize)
            continue
        }
        $ok = $true
        $usedUrl = [string]$u
        break
    } catch {
        $msg = [string]$_.Exception.Message
        if ($msg -eq 'TOO_LARGE' -or $msg -eq 'CANCELLED') {
            try { if ($fs) { $fs.Dispose() } } catch { }
            try { if ($stream) { $stream.Dispose() } } catch { }
            return (Fail $msg)
        }
        $log.Add($u + ' -> ' + (($msg -split "`r?`n")[0]))
    } finally {
        try { if ($fs) { $fs.Dispose() } } catch { }
        try { if ($stream) { $stream.Dispose() } } catch { }
        try { if ($resp) { $resp.Close() } } catch { }
    }
}
if (-not $ok) { return (Fail 'NO_SOURCE' $true) }

# ---------- 3. 收尾：.part 转正 + 整体哈希 ----------
try {
    if (Test-Path -LiteralPath $OutPath) { Remove-Item -LiteralPath $OutPath -Force -ErrorAction SilentlyContinue }
    Move-Item -LiteralPath $PartPath -Destination $OutPath -Force
} catch {
    return (Fail ('MOVE ' + (($_.Exception.Message -split "`r?`n")[0])))
}
$size = 0
try { $size = (Get-Item -LiteralPath $OutPath).Length } catch { }
$hex = ''
try { $hex = (Get-FileHash -LiteralPath $OutPath -Algorithm SHA256).Hash.ToLowerInvariant() } catch { }
return [pscustomobject]@{ ok = $true; err = ''; sha256 = $hex; size = $size; url = $usedUrl; proxy = $proxyInfo.label; log = @($log) }
'@

# ---------- 检查更新（异步） ----------
function Start-UpdateCheck {
    param([string]$Reason = 'manual')
    if ($script:UpdateCtx) { Write-AppLog ("已有任务在进行（$($script:UpdateCtx.Kind)），忽略本次检查") 'WARN'; return }
    if ($script:UpdateDelayTimer) { try { $script:UpdateDelayTimer.Stop(); $script:UpdateDelayTimer.Dispose() } catch { }; $script:UpdateDelayTimer = $null }
    $script:UpdateState = 'checking'
    Send-UpdateState @{ state = 'checking'; reason = $Reason }
    Write-AppLog ("检查更新开始（$Reason）")

    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:UpdateFetchScript)
    [void]$ps.AddParameter('ManifestUrls', $script:UpdateManifestSources)
    [void]$ps.AddParameter('TimeoutSec', 6)
    [void]$ps.AddParameter('PublicKeyXml', $script:UpdatePublicKeyXml)
    [void]$ps.AddParameter('AllowedHosts', $script:UpdateAllowedHosts)
    [void]$ps.AddParameter('NetProxyHelper', $script:NetProxyHelper)
    $handle = $ps.BeginInvoke()
    $script:UpdateCtx = @{ Kind = 'check'; PS = $ps; Handle = $handle; Reason = $Reason; Started = (Get-Date) }

    Stop-UpdateTimer
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.add_Tick({
        try { Invoke-UpdateTick } catch { Write-AppLog ('更新计时器异常: ' + $_.Exception.Message) 'WARN'; Stop-UpdateTimer }
    })
    $timer.Start()
    $script:UpdateTimer = $timer
}

function Complete-UpdateCheck {
    param($Ctx)
    $result = $null
    try { $result = $Ctx.PS.EndInvoke($Ctx.Handle) } catch { Write-AppLog ('取更新结果失败: ' + $_.Exception.Message) 'WARN' }
    try { $Ctx.PS.Dispose() } catch { }
    Stop-UpdateTimer
    $script:UpdateCtx = $null

    $obj = $null
    if ($result) { $obj = @($result)[0] }
    if (-not $obj -or -not $obj.ok) {
        $detail = ''
        if ($obj -and $obj.errors) { $detail = (@($obj.errors) -join '；') }
        if ($obj -and $obj.proxy) { $detail += '；proxy=' + $obj.proxy }
        if ($obj -and $obj.sigFail) {
            # 至少有一个源确实取到了文件，但签名对不上 —— 按被篡改处理，不降级接受
            Write-AppLog ('所有可取到的清单都验签失败，已拒绝: ' + $detail) 'WARN'
            $script:UpdateState = 'error'
            Send-UpdateState @{ state = 'error'; reason = $Ctx.Reason; detail = 'signature'; hint = 'update.hint.tampered'; sources = $detail }
            Schedule-UpdateRetry $Ctx.Reason
            return
        }
        Write-AppLog ('检查更新失败（所有源都不通）: ' + $detail) 'WARN'
        $script:UpdateState = 'error'
        Send-UpdateState @{ state = 'error'; reason = $Ctx.Reason; detail = $detail; hint = 'update.hint.offline' }
            Schedule-UpdateRetry $Ctx.Reason
        return
    }

    $bytes = [Convert]::FromBase64String($obj.manifest)
    $sig = [Convert]::FromBase64String($obj.sig)
    if (-not (Test-UpdateSignature -Bytes $bytes -Signature $sig)) {
        Write-AppLog ('清单验签失败，已拒绝: ' + $obj.url) 'WARN'
        $script:UpdateState = 'error'
        Send-UpdateState @{ state = 'error'; reason = $Ctx.Reason; detail = 'signature'; hint = 'update.hint.tampered' }
            Schedule-UpdateRetry $Ctx.Reason
        return
    }
    # 有源被跳过（签名错配 / 体积超限 / 重定向等）：正常也要记一笔，方便排查镜像问题
    if ($obj.errors -and @($obj.errors).Count) {
        Write-AppLog ('已跳过 ' + @($obj.errors).Count + ' 个清单源：' + (@($obj.errors) -join '；')) 'WARN'
    }

    $man = $null
    try { $man = ([Text.Encoding]::UTF8.GetString($bytes)) | ConvertFrom-Json } catch { }
    if (-not $man -or -not $man.version) {
        Write-AppLog '清单内容不合法（缺 version）' 'WARN'
        $script:UpdateState = 'error'
        Send-UpdateState @{ state = 'error'; reason = $Ctx.Reason; detail = 'schema'; hint = 'update.hint.tampered' }
            Schedule-UpdateRetry $Ctx.Reason
        return
    }

    $newer = (Compare-AppVersion $man.version $script:AppVersion) -gt 0
    $skipped = ($script:Cfg.updateCheck -and $script:Cfg.updateCheck.skippedVersion -eq $man.version)
    Write-AppLog ("清单版本 {0}（serial {1}），当前 {2}，来源 {3}（{4} ms，proxy={5}）" -f $man.version, $obj.serial, $script:AppVersion, $obj.url, $obj.ms, $obj.proxy)
    # 多源候选一并记下：日后排查「某镜像缓存滞后」不必再手动 curl
    if ($obj.candidates -and @($obj.candidates).Count -gt 1) {
        Write-AppLog ('多源候选：' + (@($obj.candidates | ForEach-Object { '{0}={1}/s{2}' -f $_.url, $_.version, $_.serial }) -join '；'))
    }

    if (-not $newer -or $skipped) {
        $script:UpdateState = 'latest'
        $script:UpdateAutoCheckDone = $true
        Send-UpdateState @{ state = 'latest'; reason = $Ctx.Reason; version = $man.version; source = $obj.url; skipped = [bool]$skipped }
        Set-UpdateCheckedAt
        return
    }

    $asset = $null
    if ($man.assets) { $asset = @($man.assets | Where-Object { $_.kind -eq 'setup' } | Select-Object -First 1)[0] }
    if (-not $asset -and $man.assets) { $asset = @($man.assets)[0] }
    $urls = @()
    if ($asset -and $asset.urls) { $urls = @($asset.urls | Where-Object { Test-UpdateHost $_ }) }

    # 资产元信息必须自洽：文件名不带路径（防目录穿越）、sha256 是 64 位十六进制、大小为正、地址能用
    $assetOk = [bool]$asset
    if ($assetOk) {
        if ([string]$asset.name -ne (Split-Path -Leaf ([string]$asset.name))) { $assetOk = $false }
        if ([string]$asset.sha256 -notmatch '^[0-9a-fA-F]{64}$') { $assetOk = $false }
        if (-not ([long]$asset.size -gt 0)) { $assetOk = $false }
        if (-not $urls.Count) { $assetOk = $false }
    }
    if (-not $assetOk) {
        Write-AppLog '清单里的资产信息不合法（名称/大小/哈希/地址），已拒绝' 'WARN'
        $script:UpdateState = 'error'
        Send-UpdateState @{ state = 'error'; reason = $Ctx.Reason; detail = 'asset'; hint = 'update.hint.tampered' }
        Schedule-UpdateRetry $Ctx.Reason
        return
    }

    $script:UpdateState = 'available'
    $script:UpdateAutoCheckDone = $true
    Send-UpdateState @{
        state = 'available'; reason = $Ctx.Reason
        version = $man.version; date = $man.date; notes = $man.notes
        size = $asset.size; sha256 = $asset.sha256; name = $asset.name; urls = $urls
        source = $obj.url
    }
    Set-UpdateCheckedAt
}

function Set-UpdateCheckedAt {
    try {
        if (-not $script:Cfg.updateCheck) { $script:Cfg.updateCheck = @{ auto = $true; lastCheckAt = ''; skippedVersion = '' } }
        $script:Cfg.updateCheck.lastCheckAt = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        Save-Config
    } catch { }
}

# ---------- 下载（异步，边下边算进度） ----------
function Start-UpdateDownload {
    param([string]$Name, [string[]]$Urls, [string]$Sha256, [long]$Size)
    if ($script:UpdateCtx) { Write-AppLog '已有下载/检查任务在进行' 'WARN'; return }
    # 资产名只取文件名，杜绝用 ../ 之类写到目录外
    $Name = Split-Path -Leaf ([string]$Name)
    $safe = ($Name -replace '[\\/:*?"<>|]', '_')
    if (-not $safe) { $safe = 'PerfCapture-update.exe' }
    $dir = Join-Path $env:TEMP 'PerfCapture\updates'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $out = Join-Path $dir $safe
    $part = $out + '.part'
    # .part 续传：上一轮下到一半的文件保留，只要没超过期望体积就接着用；
    # 最终仍有整包 SHA-256 兜底，续出来的字节不对会被删掉重来。
    try {
        if (Test-Path -LiteralPath $part) {
            $plen = (Get-Item -LiteralPath $part).Length
            if ($Size -gt 0 -and $plen -ge $Size) { Remove-Item -LiteralPath $part -Force }
        }
    } catch { }
    if (Test-Path $out) { Remove-Item $out -Force -ErrorAction SilentlyContinue }
    $allowed = @()
    foreach ($u in @($Urls)) {
        if ($u -and (Test-UpdateHost $u) -and ($allowed -notcontains $u)) { $allowed += [string]$u }
    }
    if (-not $allowed.Count) {
        $script:UpdateState = 'error'
        Send-UpdateState @{ state = 'error'; detail = 'url'; hint = 'update.hint.offline' }
        return
    }

    $cts = New-Object System.Threading.CancellationTokenSource
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:UpdateDownloadScript)
    [void]$ps.AddParameter('Urls', $allowed)
    [void]$ps.AddParameter('OutPath', $out)
    [void]$ps.AddParameter('PartPath', $part)
    [void]$ps.AddParameter('MaxBytes', $script:UpdateMaxAssetBytes)
    [void]$ps.AddParameter('ExpectedSize', $Size)
    [void]$ps.AddParameter('AllowedHosts', $script:UpdateAllowedHosts)
    [void]$ps.AddParameter('Token', $cts.Token)
    # 探测 6 秒定序、单次读 12 秒无数据即换源（更新包 12 MB，12 秒没有任何字节就说明这条连接废了）；
    # 45 秒宿主看门狗 ≈ 6s 探测 + 3 个源各 12s，不会在正常换源途中误杀。
    [void]$ps.AddParameter('ProbeMs', 6000)
    [void]$ps.AddParameter('StallSec', 12)
    [void]$ps.AddParameter('NetProxyHelper', $script:NetProxyHelper)
    $handle = $ps.BeginInvoke()
    $script:UpdateState = 'downloading'
    $script:UpdateCtx = @{
        Kind = 'download'; PS = $ps; Handle = $handle; Out = $out; Part = $part
        Sha = $Sha256; Size = $Size; Url = $allowed[0]; Urls = $allowed
        Cts = $cts; LastBytes = 0; LastAt = (Get-Date); Samples = $null
    }
    Send-UpdateState @{ state = 'downloading'; progress = 0; name = $safe; source = $allowed[0] }
    Write-AppLog ("开始下载更新（$($allowed.Count) 个源）: " + ($allowed -join ' | '))

    Stop-UpdateTimer
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.add_Tick({
        try { Invoke-UpdateTick } catch { Write-AppLog ('下载计时器异常: ' + $_.Exception.Message) 'WARN'; Stop-UpdateTimer }
    })
    $timer.Start()
    $script:UpdateTimer = $timer
}

function Complete-UpdateDownload {
    param($Ctx)
    $res = $null
    try { $res = @($Ctx.PS.EndInvoke($Ctx.Handle))[0] } catch { $res = [pscustomobject]@{ ok = $false; err = $_.Exception.Message; sha256 = ''; size = 0 } }
    try { $Ctx.PS.Dispose() } catch { }
    Stop-UpdateTimer
    $script:UpdateCtx = $null
    if ($Ctx.Cts) { try { $Ctx.Cts.Dispose() } catch { } }

    $err = ''
    if (-not $res) { $err = 'unknown' } elseif (-not $res.ok) { $err = [string]$res.err }

    if ($err) {
        if ($err -eq 'CANCELLED') {
            if (Test-Path -LiteralPath $Ctx.Out) { Remove-Item -LiteralPath $Ctx.Out -Force -ErrorAction SilentlyContinue }
            if ($Ctx.Part -and (Test-Path -LiteralPath $Ctx.Part)) { Remove-Item -LiteralPath $Ctx.Part -Force -ErrorAction SilentlyContinue }
            Write-AppLog '用户取消了下载'
            $script:UpdateState = 'idle'
            Send-UpdateState @{ state = 'idle'; detail = 'cancelled' }
            return
        }
        # 换源在 worker 内部完成（同一个 .part 接力），这里只负责如实汇报每个源的结果。
        $trail = ''
        if ($res -and $res.log) { $trail = '；' + (@($res.log) -join '；') }
        Write-AppLog ('下载失败: ' + $err + '；proxy=' + [string]$res.proxy + $trail) 'WARN'
        $script:UpdateState = 'error'
        Send-UpdateState @{ state = 'error'; detail = $err; hint = 'update.hint.download'; sources = $trail.TrimStart('；') }
        return
    }

    $script:UpdateState = 'verifying'
    Send-UpdateState @{ state = 'verifying'; name = (Split-Path $Ctx.Out -Leaf) }

    # 本地完整性校验：脚本边下边算的 SHA-256 + 落盘大小，都要和已验签清单一致
    $actual = 0
    $okSize = $true
    try { $actual = (Get-Item -LiteralPath $Ctx.Out).Length } catch { $okSize = $false }
    if ($Ctx.Size -gt 0) {
        $okSize = ($okSize -and $actual -eq $Ctx.Size -and [long]$res.size -eq $Ctx.Size)
        if (-not $okSize) { Write-AppLog ("资产大小不符: 期望 $($Ctx.Size)，落盘 $actual，流 $($res.size)") 'WARN' }
    }
    $okHash = $true
    if ($Ctx.Sha) {
        $okHash = ([string]$res.sha256).ToLowerInvariant() -eq ([string]$Ctx.Sha).ToLowerInvariant()
        if (-not $okHash) { Write-AppLog ("SHA-256 不符: 期望 $($Ctx.Sha)，实际 $($res.sha256)") 'WARN' }
    }
    if (-not ($okSize -and $okHash)) {
        Remove-Item -LiteralPath $Ctx.Out -Force -ErrorAction SilentlyContinue
        # 校验不过说明字节不可信：连 .part 一起删，下次从头下（不能拿半截包续一个可能已换版的镜像）。
        if ($Ctx.Part -and (Test-Path -LiteralPath $Ctx.Part)) { Remove-Item -LiteralPath $Ctx.Part -Force -ErrorAction SilentlyContinue }
        $script:UpdateState = 'error'
        Send-UpdateState @{ state = 'error'; detail = 'integrity'; hint = 'update.hint.tampered' }
        return
    }

    $script:UpdateState = 'ready'
    Send-UpdateState @{ state = 'ready'; name = (Split-Path $Ctx.Out -Leaf); path = $Ctx.Out; sha256 = $Ctx.Sha }
    Write-AppLog ("更新包已下载并通过本地校验: $($Ctx.Out)（源 " + [string]$res.url + "，proxy=" + [string]$res.proxy + "）")
}

# ---------- 计时器总入口 ----------
function Invoke-UpdateTick {
    $ctx = $script:UpdateCtx
    if (-not $ctx) { Stop-UpdateTimer; return }

    if ($ctx.Kind -eq 'check') {
        if (-not $ctx.Handle.IsCompleted) {
            if (((Get-Date) - $ctx.Started).TotalSeconds -gt 45) {
                try { $ctx.PS.Stop() } catch { }
                try { $ctx.PS.Dispose() } catch { }
                $script:UpdateCtx = $null
                Stop-UpdateTimer
                $script:UpdateState = 'error'
                Send-UpdateState @{ state = 'error'; detail = 'timeout'; hint = 'update.hint.offline' }
            }
            return
        }
        Complete-UpdateCheck -Ctx $ctx
        return
    }

    if ($ctx.Kind -eq 'download') {
        $len = 0
        # 进度读 .part：下载期间数据只写 .part，完成后 worker 才把它转正。
        try {
            if ($ctx.Part -and (Test-Path -LiteralPath $ctx.Part)) { $len = (Get-Item -LiteralPath $ctx.Part).Length }
            elseif (Test-Path -LiteralPath $ctx.Out) { $len = (Get-Item -LiteralPath $ctx.Out).Length }
        } catch { }
        if ($len -ne $ctx.LastBytes) { $ctx.LastBytes = $len; $ctx.LastAt = Get-Date }
        $pct = 0
        if ($ctx.Size -gt 0) { $pct = [int][Math]::Min(99, [Math]::Floor(100.0 * $len / $ctx.Size)) }
        # 速度/剩余时间：用最近若干次采样的增量算，单次抖动不会让数字乱跳。
        if (-not $ctx.Samples) { $ctx.Samples = New-Object System.Collections.Generic.Queue[object] }
        $ctx.Samples.Enqueue(@((Get-Date), $len))
        while ($ctx.Samples.Count -gt 9) { [void]$ctx.Samples.Dequeue() }
        $bps = 0
        $eta = -1
        if ($ctx.Samples.Count -gt 1) {
            $first = @($ctx.Samples.Peek())
            $dt = ((Get-Date) - $first[0]).TotalSeconds
            if ($dt -gt 0.8) {
                $delta = $len - [long]$first[1]
                if ($delta -gt 0) { $bps = [int64]($delta / $dt) }
            }
        }
        if ($bps -gt 0 -and $ctx.Size -gt $len) { $eta = [int][Math]::Ceiling(($ctx.Size - $len) / [double]$bps) }
        Send-UpdateState @{ state = 'downloading'; progress = $pct; received = $len; size = $ctx.Size; bps = $bps; eta = $eta; name = (Split-Path $ctx.Out -Leaf) }
        if ($ctx.Handle.IsCompleted) { Complete-UpdateDownload -Ctx $ctx; return }
        # 停滞看门狗：45 秒没有任何新增（探测 6s + 单次读 20s 都在其内）就整体放弃。
        # 换源由 worker 内部用同一个 .part 接力完成，这里只在「连 worker 都卡住」时兜底。
        if (((Get-Date) - $ctx.LastAt).TotalSeconds -gt 45) {
            Write-AppLog '下载停滞超过 45 秒，放弃本次下载' 'WARN'
            try { $ctx.Cts.Cancel() } catch { }
            try { $ctx.PS.Stop() } catch { }
            try { $ctx.PS.Dispose() } catch { }
            $script:UpdateCtx = $null
            Stop-UpdateTimer
            $script:UpdateState = 'error'
            Send-UpdateState @{ state = 'error'; detail = 'stalled'; hint = 'update.hint.download' }
        }
        return
    }
}

# ---------- 启动后自动检查一次 ----------
function Start-UpdateAutoCheck {
    if ($script:Cfg.updateCheck -and $script:Cfg.updateCheck.auto -eq $false) { Write-AppLog '自动检查更新已在设置里关闭'; return }
    if ($script:UpdateAutoCheckDone) { return }
    Write-AppLog ("将在 {0} 秒后自动检查一次更新（本次会话只查一次）" -f [int]($script:UpdateAutoCheckDelayMs / 1000))
    $delay = New-Object System.Windows.Forms.Timer
    $delay.Interval = $script:UpdateAutoCheckDelayMs
    $delay.add_Tick({
        try { $delay.Stop(); $delay.Dispose() } catch { }
        if ($script:UpdateAutoCheckDone) { return }
        $script:UpdateAutoCheckDone = $true
        Start-UpdateCheck -Reason 'auto'
    })
    $delay.Start()
    $script:UpdateDelayTimer = $delay
}

# ---------- 检查失败：等 15 秒再来一次（启动自动检查最多 10 次；手动检查不重试） ----------
function Schedule-UpdateRetry([string]$Reason) {
    # 手动点的检查：失败就失败，不自动重试（用户就在屏幕前，让他自己决定）
    if ($Reason -eq 'manual') { return }
    if ($script:Cfg.updateCheck -and $script:Cfg.updateCheck.auto -eq $false) { return }
    if ($script:UpdateRetryCount -ge 10) {
        Write-AppLog '检查更新连续失败 10 次，本次会话不再重试'
        return
    }
    $script:UpdateRetryCount++
    if ($script:UpdateRetryTimer) { try { $script:UpdateRetryTimer.Stop(); $script:UpdateRetryTimer.Dispose() } catch { }; $script:UpdateRetryTimer = $null }
    $n = $script:UpdateRetryCount
    $rt = New-Object System.Windows.Forms.Timer
    $rt.Interval = 15000
    $rt.add_Tick({
        try { $rt.Stop(); $rt.Dispose() } catch { }
        $script:UpdateRetryTimer = $null
        Write-AppLog ("检查更新失败，15 秒后自动重试（第 {0} / 10 次）" -f $n)
        Start-UpdateCheck -Reason 'retry'
    })
    $rt.Start()
    $script:UpdateRetryTimer = $rt
    Write-AppLog ("检查更新失败（$Reason），15 秒后重试（第 $n 次）")
}

# ---------- 校验并定位下载好的安装包（只认更新目录内的文件 + 二次校验哈希） ----------
function Resolve-UpdateInstaller([string]$path, [string]$sha256) {
    $root = [IO.Path]::GetFullPath((Join-Path $env:TEMP 'PerfCapture\updates'))
    $full = ''
    try { $full = [IO.Path]::GetFullPath($path) } catch { }
    # 只允许运行我们自己下载到临时目录里的文件（UI 消息被伪造也执行不到别处）
    if (-not $full -or -not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $full)) {
        Write-AppLog ('拒绝运行不在更新目录内的文件: ' + $path) 'ERROR'
        Send-UpdateState @{ state = 'error'; detail = 'path'; hint = 'update.hint.tampered' }
        return $null
    }
    if ($sha256 -match '^[0-9a-fA-F]{64}$') {
        $h = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($h -ne $sha256.ToLowerInvariant()) {
            Write-AppLog '安装包哈希已变化，拒绝运行' 'ERROR'
            Send-UpdateState @{ state = 'error'; detail = 'integrity'; hint = 'update.hint.tampered' }
            return $null
        }
    } else {
        Write-AppLog '缺少可用哈希，拒绝运行安装包' 'ERROR'
        Send-UpdateState @{ state = 'error'; detail = 'integrity'; hint = 'update.hint.tampered' }
        return $null
    }
    return $full
}

# ---------- 当前安装目录（更新要直接覆盖这里，不再让用户选路径） ----------
function Get-UpdateInstallDir {
    try {
        $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PerfCapture'
        if (Test-Path $reg) {
            $v = (Get-ItemProperty -Path $reg -Name 'InstallLocation' -ErrorAction SilentlyContinue).InstallLocation
            if ($v -and (Test-Path -LiteralPath $v)) { return [IO.Path]::GetFullPath([string]$v) }
        }
    } catch { }
    # 没有注册表信息（绿色版）就覆盖当前正在运行的这份
    if ($script:Root) { return [IO.Path]::GetFullPath($script:Root) }
    return ''
}

# ---------- 更新安装窗口起来后，退出当前进程 ----------
# 不退出的话安装程序写 lib\*.dll 会被占用（实测 IOException），用户眼前也会留个旧实例。
function Request-AppExitForUpdate {
    $script:UpdateExitRequested = $true
    if ($script:UpdateExitTimer) { try { $script:UpdateExitTimer.Stop(); $script:UpdateExitTimer.Dispose() } catch { }; $script:UpdateExitTimer = $null }
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 1500
    $t.add_Tick({
        try { $t.Stop(); $t.Dispose() } catch { }
        $script:UpdateExitTimer = $null
        try {
            if ($script:MainForm) { $script:MainForm.Close() }
            elseif ($form) { $form.Close() }
        } catch {
            Write-AppLog ('退出进程失败: ' + $_.Exception.Message) 'WARN'
        }
    })
    $t.Start()
    $script:UpdateExitTimer = $t
}

# ---------- 公开操作（供桥接调用） ----------
function Invoke-UpdateCommand {
    param($Msg)
    switch ($Msg.cmd) {
        'checkUpdate' { Start-UpdateCheck -Reason 'manual' }
        'downloadUpdate' {
            $urls = @($Msg.urls | Where-Object { $_ })
            Start-UpdateDownload -Name ([string]$Msg.name) -Urls $urls -Sha256 ([string]$Msg.sha256) -Size ([long]$Msg.size)
        }
        'cancelUpdate' {
            if ($script:UpdateCtx) {
                try { if ($script:UpdateCtx.Cts) { $script:UpdateCtx.Cts.Cancel() } } catch { }
                try { $script:UpdateCtx.PS.Stop() } catch { }
                try { $script:UpdateCtx.PS.Dispose() } catch { }
                # 取消后不留半截文件（含 .part），免得下次续到一个用户以为已取消的包上
                try {
                    foreach ($p in @($script:UpdateCtx.Out, $script:UpdateCtx.Part)) {
                        if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
                    }
                } catch { }
                $script:UpdateCtx = $null
            }
            Stop-UpdateTimer
            $script:UpdateState = 'idle'
            Send-UpdateState @{ state = 'idle'; detail = 'cancelled'; current = $script:AppVersion }
        }
        'openUpdatePage' {
            try { Start-Process 'https://github.com/yousouyouka/PerfCapture/releases' } catch { }
        }
        'runUpdateInstaller' {
            $full = Resolve-UpdateInstaller ([string]$Msg.path) ([string]$Msg.sha256)
            if (-not $full) { return }
            try { Start-Process -FilePath $full } catch { Write-AppLog ('启动安装包失败: ' + $_.Exception.Message) 'ERROR' }
        }
        'applyUpdate' {
            # 用户点了「立即更新」：静默覆盖安装到**当前安装目录**（不弹路径选择、不建快捷方式），
            # 安装完成后自动运行新版本，并把当前进程退出（否则 lib\*.dll 被占用）。
            $full = Resolve-UpdateInstaller ([string]$Msg.path) ([string]$Msg.sha256)
            if (-not $full) { return }
            $dir = Get-UpdateInstallDir
            try {
                $args = @('/S', ('/D="' + $dir + '"'), '/NODESKTOP', '/NOMENU', '/RUN')
                Write-AppLog ('启动安装程序（静默覆盖）: ' + $full + ' → ' + $dir)
                Start-Process -FilePath $full -ArgumentList $args
                Request-AppExitForUpdate
            } catch {
                Write-AppLog ('启动安装包失败: ' + $_.Exception.Message) 'ERROR'
                Send-UpdateState @{ state = 'error'; detail = 'launch'; hint = 'update.hint.download' }
            }
        }
        'openUpdateFolder' {
            $path = [string]$Msg.path
            $root = [IO.Path]::GetFullPath((Join-Path $env:TEMP 'PerfCapture\updates'))
            $full = ''
            try { $full = [IO.Path]::GetFullPath($path) } catch { }
            if ($full -and $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full)) {
                try { Start-Process 'explorer.exe' ('/select,"' + $full + '"') } catch { }
            } else {
                try { Start-Process 'explorer.exe' $root } catch { }
            }
        }
        'skipUpdateVersion' {
            $v = [string]$Msg.version
            if ($v) {
                if (-not $script:Cfg.updateCheck) { $script:Cfg.updateCheck = @{ auto = $true; lastCheckAt = ''; skippedVersion = '' } }
                $script:Cfg.updateCheck.skippedVersion = $v
                Save-Config
                Write-AppLog ("已跳过版本 $v")
                Send-UpdateState @{ state = 'latest'; version = $v; skipped = $true }
            }
        }
        'setUpdateAuto' {
            $on = [bool]$Msg.auto
            if (-not $script:Cfg.updateCheck) { $script:Cfg.updateCheck = @{ auto = $true; lastCheckAt = ''; skippedVersion = '' } }
            $script:Cfg.updateCheck.auto = $on
            Save-Config
            Send-UpdateState @{ state = $script:UpdateState; auto = $on; current = $script:AppVersion }
        }
    }
}
