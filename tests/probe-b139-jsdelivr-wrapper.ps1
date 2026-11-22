# B139 M2（B0 可行性试验）：wrapper zip 结构自证 + jsDelivr 可达性实测。
# B0 门槛：成功率 ≥80% 且平均 ≥1 MB/s 才继续做 M3；本机只测一个样本，
# 网络不可达时如实记为「需国内用户实测」，不把结构测试失败和网络失败混为一谈。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b139-jsdelivr-wrapper.ps1

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Warn([string]$m) { Write-Host "  ⚠ $m" -ForegroundColor Yellow }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host '== B139 M2 / B0 jsDelivr 包装 zip 可行性 ==' -ForegroundColor Cyan

# ---------- 1. 从已签名清单取 setup 资产（唯一可信来源） ----------
$man = Get-Content (Join-Path $root 'updates\latest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$setup = @($man.assets | Where-Object { $_.kind -eq 'setup' })[0]
Assert ($null -ne $setup) '清单里有 setup 资产' '清单缺 setup 资产'
$version = [string]$man.version
$setupPath = Join-Path $root ('dist\' + [string]$setup.name)
Assert (Test-Path -LiteralPath $setupPath) "本地存在 $($setup.name)" "本地缺 $($setup.name)"
if (-not (Test-Path -LiteralPath $setupPath)) { exit 1 }
$setupSha = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
Assert ($setupSha -eq [string]$setup.sha256) '安装包与清单 sha256 一致' '安装包与清单 sha256 不符'

# ---------- 2. 生成 wrapper zip（内层就是 setup exe，不解压安装） ----------
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$work = Join-Path $env:TEMP ('PerfCapture-B139-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$wrapperName = 'PerfCapture-Update-' + $version + '.zip'
$wrapper = Join-Path $work $wrapperName
$za = [IO.Compression.ZipFile]::Open($wrapper, [IO.Compression.ZipArchiveMode]::Create)
try {
    $entry = $za.CreateEntry([string]$setup.name, [IO.Compression.CompressionLevel]::Optimal)
    # 固定条目时间：否则每次试验生成的 zip 哈希都不同，给用户核对就无从谈起。
    $entry.LastWriteTime = (Get-Item -LiteralPath $setupPath).LastWriteTime
    $dst = $entry.Open()
    $src = [IO.File]::OpenRead($setupPath)
    try { $src.CopyTo($dst) } finally { $src.Dispose(); $dst.Dispose() }
} finally { $za.Dispose() }
$wrapperSize = (Get-Item -LiteralPath $wrapper).Length
$wrapperSha = (Get-FileHash -LiteralPath $wrapper -Algorithm SHA256).Hash.ToLowerInvariant()
Assert ($wrapperSize -lt 20MB) ("wrapper 体积 {0:N2} MB，在 jsDelivr 20 MB 限制内" -f ($wrapperSize / 1MB)) ("wrapper 超过 20 MB: {0:N2} MB" -f ($wrapperSize / 1MB))

# ---------- 3. 回读内层哈希：防止「包好了但里面不是那个 exe」 ----------
$za2 = [IO.Compression.ZipFile]::OpenRead($wrapper)
try {
    $names = @($za2.Entries | ForEach-Object { $_.FullName })
    Assert ($names.Count -eq 1 -and $names[0] -eq [string]$setup.name) 'wrapper 里只有一个 setup exe' ('条目异常: ' + ($names -join ','))
    $stream = $za2.Entries[0].Open()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $innerSha = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
} finally { $za2.Dispose() }
Assert ($innerSha -eq $setupSha) '内层 exe 的 SHA-256 与清单一致' ("内层哈希不符: $innerSha")

$jsdUrl = 'https://cdn.jsdelivr.net/gh/yousouyouka/PerfCapture@updates/bin/' + $wrapperName
Write-Host ''
Write-Host '  B0 试验资产（已推送 updates 分支，清单未引用，不影响现有用户）：' -ForegroundColor Cyan
Write-Host "    文件: $wrapperName"
Write-Host "    大小: $wrapperSize B"
Write-Host "    SHA-256: $wrapperSha"
Write-Host "    目标地址: $jsdUrl"
Write-Host "    本地临时副本: $wrapper"
Write-Host ''

# ---------- 4. jsDelivr 实测：HEAD / Range / 整包下载 ----------
. (Join-Path $root 'src\app\06-NetProxy.ps1')
$pi = Get-NetProxyDescriptor $jsdUrl
Write-Host ("  本机网络: proxy={0}" -f $pi.label)
function Invoke-Probe([string]$url, $pi) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        [void](Set-RequestProxy $req $pi)
        $req.Method = 'HEAD'
        $req.Timeout = 10000
        $req.ReadWriteTimeout = 10000
        $resp = $req.GetResponse()
        $status = [int]$resp.StatusCode
        $len = [int64]$resp.ContentLength
        $resp.Close()
        return [pscustomobject]@{ ok = $true; status = $status; length = $len; ttfb = $sw.ElapsedMilliseconds; error = '' }
    } catch {
        return [pscustomobject]@{ ok = $false; status = 0; length = 0; ttfb = $sw.ElapsedMilliseconds; error = (($_.Exception.Message -split "`r?`n")[0]) }
    }
}
function Invoke-Range([string]$url, $pi) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $buf = New-Object byte[] 4096
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        [void](Set-RequestProxy $req $pi)
        $req.Method = 'GET'
        $req.Timeout = 12000
        $req.ReadWriteTimeout = 12000
        $req.AddRange(0, 1023)
        $resp = $req.GetResponse()
        $status = [int]$resp.StatusCode
        $got = [int64]0
        try {
            while (($n = $resp.GetResponseStream().Read($buf, 0, $buf.Length)) -gt 0) { $got += $n }
        } finally { $resp.Close() }
        return [pscustomobject]@{ ok = $true; status = $status; bytes = $got; ttfb = $sw.ElapsedMilliseconds; error = '' }
    } catch {
        return [pscustomobject]@{ ok = $false; status = 0; bytes = 0; ttfb = $sw.ElapsedMilliseconds; error = (($_.Exception.Message -split "`r?`n")[0]) }
    }
}
function Invoke-Download([string]$url, $pi, [string]$out, [int64]$limit) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        [void](Set-RequestProxy $req $pi)
        $req.Timeout = 10000
        $req.ReadWriteTimeout = 15000
        $resp = $req.GetResponse()
        $fs = [IO.File]::Create($out)
        $buf = New-Object byte[] 65536
        $got = [int64]0
        try {
            while (($n = $resp.GetResponseStream().Read($buf, 0, $buf.Length)) -gt 0) {
                $fs.Write($buf, 0, $n); $got += $n
                if ($got -gt $limit) { throw 'tooLarge' }
            }
        } finally { $fs.Dispose(); $resp.Close() }
        $sec = [math]::Max(0.001, $sw.Elapsed.TotalSeconds)
        return [pscustomobject]@{ ok = $true; bytes = $got; seconds = $sec; mbps = ($got / $sec / 1MB); error = '' }
    } catch {
        return [pscustomobject]@{ ok = $false; bytes = 0; seconds = 0; mbps = 0; error = (($_.Exception.Message -split "`r?`n")[0]) }
    }
}

# 对照组：分支上已有的 zip。若它可达而 wrapper 403，说明只是 wrapper 还没推上去。
$controlUrl = 'https://cdn.jsdelivr.net/gh/yousouyouka/PerfCapture@updates/bin/PerfCapture-' + $version + '.zip'
$control = Invoke-Probe $controlUrl $pi
if ($control.ok) {
    Ok ("对照组（已有 zip）可达：HTTP {0} / {1:N0} B / TTFB {2} ms" -f $control.status, $control.length, $control.ttfb)
    # 对照组体积与 wrapper 几乎一样，先拿它量一次真实下载速度（B0 的 1 MB/s 门槛）。
    $zipAsset = @($man.assets | Where-Object { $_.kind -eq 'zip' })[0]
    $cdl = Invoke-Download $controlUrl $pi (Join-Path $work 'control.zip') 20971520
    if ($cdl.ok) {
        $csha = (Get-FileHash -LiteralPath (Join-Path $work 'control.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($zipAsset) { Assert ($csha -eq [string]$zipAsset.sha256) '对照组下载内容与清单一致' "对照组哈希不符: $csha" }
        if ($cdl.mbps -ge 1) { Ok ("对照组平均速度 {0:N2} MB/s，达到 B0 门槛" -f $cdl.mbps) }
        else { Warn ("对照组平均速度 {0:N2} MB/s，低于 B0 的 1 MB/s 门槛" -f $cdl.mbps) }
    } else { Warn ("对照组整包下载失败：{0}" -f $cdl.error) }
}
else { Warn ("对照组（已有 zip）也不可达：{0}" -f $control.error) }

$head = Invoke-Probe $jsdUrl $pi
if ($head.ok) {
    Ok ("jsDelivr HEAD 可达：HTTP {0} / {1:N0} B / TTFB {2} ms" -f $head.status, $head.length, $head.ttfb)
    Assert ($head.length -eq $wrapperSize -or $head.length -le 0) 'HEAD 长度与本地 wrapper 一致' "HEAD 长度 $($head.length) ≠ 本地 $wrapperSize"
    $rg = Invoke-Range $jsdUrl $pi
    Assert ($rg.ok -and $rg.status -eq 206 -and $rg.bytes -eq 1024) ("Range 续传可用：HTTP {0} / {1} B / TTFB {2} ms" -f $rg.status, $rg.bytes, $rg.ttfb) ("Range 不可用：HTTP {0} / {1} B / {2}" -f $rg.status, $rg.bytes, $rg.error)
    $dl = Invoke-Download $jsdUrl $pi (Join-Path $work 'downloaded.zip') 20971520
    if ($dl.ok) {
        $gotSha = (Get-FileHash -LiteralPath (Join-Path $work 'downloaded.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert ($gotSha -eq $wrapperSha) '下载回来的 wrapper 哈希一致' '下载内容哈希不符'
        if ($dl.mbps -ge 1) { Ok ("平均速度 {0:N2} MB/s，达到 B0 门槛" -f $dl.mbps) } else { Warn ("平均速度 {0:N2} MB/s，低于 B0 的 1 MB/s 门槛" -f $dl.mbps) }
    } else {
        Warn ("整包下载失败：{0}" -f $dl.error)
    }
} else {
    if (($head.status -eq 403 -or $head.status -eq 404) -and $control.ok) {
        Warn 'wrapper 文件尚未被 jsDelivr 收录（对不存在的路径回 403/404）；推送后清一次 CDN 缓存再重跑本探针即可实测。'
    } else {
        Warn ("本机探测 jsDelivr 失败（{0}，{1} ms）：{2}" -f $head.status, $head.ttfb, $head.error)
    }
    Warn '这不代表国内用户不可达；按规划 B0 需找 2–3 位国内用户各自下载一次再判定。'
}

Write-Host ''
Write-Host '  给用户实测时请转发：' -ForegroundColor Cyan
Write-Host ("    {0}" -f $jsdUrl)
Write-Host ("    预期 SHA-256: {0}" -f $wrapperSha)
Write-Host ("    判定：3 人中 ≥2 人成功且平均 ≥1 MB/s → 做 M3；否则转 C 自建镜像。")
Write-Host ''
Write-Host ("== B139 完成：{0} 项结构断言失败（网络结论单独记录） ==" -f $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
if ($fail) { exit 1 }
