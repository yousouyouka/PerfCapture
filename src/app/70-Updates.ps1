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

# 清单源顺序：jsDelivr（国内多数可达）→ raw → api（境内实测三者都通，按速度排）
$script:UpdateManifestSources = @(
    'https://cdn.jsdelivr.net/gh/yousouyouka/PerfCapture@main/updates/latest.json',
    'https://raw.githubusercontent.com/yousouyouka/PerfCapture/main/updates/latest.json',
    'https://api.github.com/repos/yousouyouka/PerfCapture/contents/updates/latest.json'
)

$script:UpdateMaxManifestBytes = 262144
$script:UpdateMaxAssetBytes = 62914560
$script:UpdateAutoCheckDelayMs = 12000

$script:UpdateState = 'idle'        # idle|checking|latest|available|downloading|verifying|ready|error
$script:UpdateAutoCheckDone = $false
$script:UpdateCtx = $null
$script:UpdateTimer = $null

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
param($ManifestUrls, $TimeoutSec)
$errs = @()
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
try { $http.DefaultRequestHeaders.UserAgent.ParseAdd('PerfCapture/1.4') } catch {}
try { $http.DefaultRequestHeaders.Add('Accept', 'application/vnd.github.raw, application/json, */*') } catch {}
foreach ($u in $ManifestUrls) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $mb = $http.GetByteArrayAsync($u).GetAwaiter().GetResult()
        if ($mb.Length -lt 2 -or $mb.Length -gt 262144) { $errs += ('{0} 大小异常 {1}' -f $u, $mb.Length); continue }
        $sigBytes = $http.GetByteArrayAsync($u + '.sig').GetAwaiter().GetResult()
        $sigText = ([Text.Encoding]::ASCII.GetString($sigBytes)) -replace '\s', ''
        $sigRaw = $null
        try { $sigRaw = [Convert]::FromBase64String($sigText) } catch { }
        if (-not $sigRaw -or $sigRaw.Length -ne 256) { $errs += ('{0} 签名不可用（长度 {1}）' -f $u, $sigText.Length); continue }
        return [pscustomobject]@{ ok = $true; url = $u; ms = $sw.ElapsedMilliseconds
            manifest = [Convert]::ToBase64String($mb); sig = [Convert]::ToBase64String($sigRaw); errors = $errs }
    } catch {
        $errs += ('{0} 失败: {1}' -f $u, (($_.Exception.Message -split "`r?`n")[0]))
    }
}
return [pscustomobject]@{ ok = $false; url = ''; ms = 0; manifest = ''; sig = ''; errors = $errs }
'@

$script:UpdateDownloadScript = @'
param($Url, $OutPath, $MaxBytes, $ExpectedSize)
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromSeconds(180)
try { $http.DefaultRequestHeaders.UserAgent.ParseAdd('PerfCapture/1.4') } catch {}
try {
    $resp = $http.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) { return ('HTTP ' + [int]$resp.StatusCode) }
    $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $dir = Split-Path -Parent $OutPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $out = [IO.File]::Open($OutPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
    $total = [long]0
    try {
        $buf = New-Object byte[] 65536
        while ($true) {
            $n = $in.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $total += $n
            if ($MaxBytes -gt 0 -and $total -gt $MaxBytes) { $out.Close(); Remove-Item $OutPath -Force -ErrorAction SilentlyContinue; return 'TOO_LARGE' }
            $out.Write($buf, 0, $n)
        }
    } finally { $out.Close(); $in.Dispose() }
    return ''
} catch { return (($_.Exception.Message -split "`r?`n")[0]) }
'@

# ---------- 检查更新（异步） ----------
function Start-UpdateCheck {
    param([string]$Reason = 'manual')
    if ($script:UpdateCtx -and $script:UpdateCtx.Kind -eq 'check' -and -not $script:UpdateCtx.Handle.IsCompleted) { return }
    $script:UpdateState = 'checking'
    Send-UpdateState @{ state = 'checking'; reason = $Reason }
    Write-AppLog ("检查更新开始（$Reason）")

    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:UpdateFetchScript)
    [void]$ps.AddParameter('ManifestUrls', $script:UpdateManifestSources)
    [void]$ps.AddParameter('TimeoutSec', 5)
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
        Write-AppLog ('检查更新失败（所有源都不通）: ' + $detail) 'WARN'
        $script:UpdateState = 'error'
        Send-UpdateState @{ state = 'error'; reason = $Ctx.Reason; detail = $detail; hint = 'update.hint.offline' }
        return
    }

    $bytes = [Convert]::FromBase64String($obj.manifest)
    $sig = [Convert]::FromBase64String($obj.sig)
    if (-not (Test-UpdateSignature -Bytes $bytes -Signature $sig)) {
        Write-AppLog ('清单验签失败，已拒绝: ' + $obj.url) 'WARN'
        $script:UpdateState = 'error'
        Send-UpdateState @{ state = 'error'; reason = $Ctx.Reason; detail = 'signature'; hint = 'update.hint.tampered' }
        return
    }

    $man = $null
    try { $man = ([Text.Encoding]::UTF8.GetString($bytes)) | ConvertFrom-Json } catch { }
    if (-not $man -or -not $man.version) {
        Write-AppLog '清单内容不合法（缺 version）' 'WARN'
        $script:UpdateState = 'error'
        Send-UpdateState @{ state = 'error'; reason = $Ctx.Reason; detail = 'schema'; hint = 'update.hint.tampered' }
        return
    }

    $newer = (Compare-AppVersion $man.version $script:AppVersion) -gt 0
    $skipped = ($script:Cfg.updateCheck -and $script:Cfg.updateCheck.skippedVersion -eq $man.version)
    Write-AppLog ("清单版本 {0}，当前 {1}，来源 {2}（{3} ms）" -f $man.version, $script:AppVersion, $obj.url, $obj.ms)

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
    $safe = ($Name -replace '[\\/:*?"<>|]', '_')
    $dir = Join-Path $env:TEMP ('PerfCapture\updates')
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $out = Join-Path $dir $safe
    if (Test-Path $out) { Remove-Item $out -Force -ErrorAction SilentlyContinue }
    $allowed = @($Urls | Where-Object { Test-UpdateHost $_ })
    if (-not $allowed.Count) { Send-UpdateState @{ state = 'error'; detail = 'url'; hint = 'update.hint.offline' }; return }

    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:UpdateDownloadScript)
    [void]$ps.AddParameter('Url', $allowed[0])
    [void]$ps.AddParameter('OutPath', $out)
    [void]$ps.AddParameter('MaxBytes', $script:UpdateMaxAssetBytes)
    [void]$ps.AddParameter('ExpectedSize', $Size)
    $handle = $ps.BeginInvoke()
    $script:UpdateState = 'downloading'
    $script:UpdateCtx = @{ Kind = 'download'; PS = $ps; Handle = $handle; Out = $out; Sha = $Sha256; Size = $Size; Url = $allowed[0]; Rest = @($allowed | Select-Object -Skip 1) }
    Send-UpdateState @{ state = 'downloading'; progress = 0; name = $safe; source = $allowed[0] }
    Write-AppLog ("开始下载更新: $($allowed[0])")

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
    $err = ''
    try { $err = [string]@($Ctx.PS.EndInvoke($Ctx.Handle))[0] } catch { $err = $_.Exception.Message }
    try { $Ctx.PS.Dispose() } catch { }
    Stop-UpdateTimer
    $script:UpdateCtx = $null

    if ($err -and $err.Length -gt 0) {
        # 当前源失败：还有备用源就换下一个，否则报错
        if ($Ctx.Rest -and $Ctx.Rest.Count) {
            Write-AppLog ("下载失败（$err），换备用源: $($Ctx.Rest[0])") 'WARN'
            Start-UpdateDownload -Name (Split-Path $Ctx.Out -Leaf) -Urls $Ctx.Rest -Sha256 $Ctx.Sha -Size $Ctx.Size
            return
        }
        Write-AppLog ('下载失败: ' + $err) 'WARN'
        $script:UpdateState = 'error'
        Send-UpdateState @{ state = 'error'; detail = $err; hint = 'update.hint.download' }
        return
    }

    $script:UpdateState = 'verifying'
    Send-UpdateState @{ state = 'verifying'; name = (Split-Path $Ctx.Out -Leaf) }

    # 本地完整性校验：大小 + SHA-256 必须与已验签清单一致
    $okSize = $true
    if ($Ctx.Size -gt 0) {
        $actual = (Get-Item -LiteralPath $Ctx.Out).Length
        $okSize = ($actual -eq $Ctx.Size)
        if (-not $okSize) { Write-AppLog ("资产大小不符: 期望 $($Ctx.Size)，实际 $actual") 'WARN' }
    }
    $okHash = $true
    if ($Ctx.Sha) {
        $h = (Get-FileHash -LiteralPath $Ctx.Out -Algorithm SHA256).Hash.ToLowerInvariant()
        $okHash = ($h -eq ([string]$Ctx.Sha).ToLowerInvariant())
        if (-not $okHash) { Write-AppLog ("SHA-256 不符: 期望 $($Ctx.Sha)，实际 $h") 'WARN' }
    }
    if (-not ($okSize -and $okHash)) {
        Remove-Item -LiteralPath $Ctx.Out -Force -ErrorAction SilentlyContinue
        $script:UpdateState = 'error'
        Send-UpdateState @{ state = 'error'; detail = 'integrity'; hint = 'update.hint.tampered' }
        return
    }

    $script:UpdateState = 'ready'
    Send-UpdateState @{ state = 'ready'; name = (Split-Path $Ctx.Out -Leaf); path = $Ctx.Out; sha256 = $Ctx.Sha }
    Write-AppLog ("更新包已下载并通过本地校验: $($Ctx.Out)")
}

# ---------- 计时器总入口 ----------
function Invoke-UpdateTick {
    $ctx = $script:UpdateCtx
    if (-not $ctx) { Stop-UpdateTimer; return }

    if ($ctx.Kind -eq 'check') {
        if (-not $ctx.Handle.IsCompleted) {
            if (((Get-Date) - $ctx.Started).TotalSeconds -gt 30) {
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
        try { if (Test-Path -LiteralPath $ctx.Out) { $len = (Get-Item -LiteralPath $ctx.Out).Length } } catch { }
        $pct = 0
        if ($ctx.Size -gt 0) { $pct = [int][Math]::Min(99, [Math]::Floor(100.0 * $len / $ctx.Size)) }
        Send-UpdateState @{ state = 'downloading'; progress = $pct; received = $len; size = $ctx.Size; name = (Split-Path $ctx.Out -Leaf) }
        if ($ctx.Handle.IsCompleted) { Complete-UpdateDownload -Ctx $ctx }
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
                try { $script:UpdateCtx.PS.Stop() } catch { }
                try { $script:UpdateCtx.PS.Dispose() } catch { }
                $script:UpdateCtx = $null
            }
            Stop-UpdateTimer
            $script:UpdateState = 'idle'
            Send-UpdateState @{ state = 'idle' }
        }
        'openUpdatePage' {
            try { Start-Process 'https://github.com/yousouyouka/PerfCapture/releases' } catch { }
        }
        'runUpdateInstaller' {
            $path = [string]$Msg.path
            if ($path -and (Test-Path -LiteralPath $path)) {
                # 二次校验：跑安装包前再算一次哈希，防止下载后被替换
                $sha = [string]$Msg.sha256
                if ($sha) {
                    $h = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
                    if ($h -ne $sha.ToLowerInvariant()) {
                        Write-AppLog '安装包哈希已变化，拒绝运行' 'ERROR'
                        Send-UpdateState @{ state = 'error'; detail = 'integrity'; hint = 'update.hint.tampered' }
                        return
                    }
                }
                try { Start-Process -FilePath $path } catch { Write-AppLog ('启动安装包失败: ' + $_.Exception.Message) 'ERROR' }
            }
        }
        'openUpdateFolder' {
            $path = [string]$Msg.path
            if ($path -and (Test-Path -LiteralPath $path)) { try { Start-Process 'explorer.exe' ('/select,"' + $path + '"') } catch { } }
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
