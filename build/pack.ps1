# PerfCapture 打包脚本
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File build\pack.ps1 [-Version 1.0.0] [-NoZip]
# 产物：dist\PerfCapture-<版本>\ 与 dist\PerfCapture-<版本>.zip
[CmdletBinding()]
param(
    [string]$Version = '',
    [switch]$NoZip,
    [string]$ReleaseDate = '',   # 更新清单里的发布日期（默认今天；发版时显式传）
    [switch]$NoManifest          # 只打包、不生成更新清单（调试用）
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$buildDir = $PSScriptRoot
$root     = Split-Path $buildDir -Parent
$distRoot = Join-Path $root 'dist'

if (-not $Version) {
    $vf = Join-Path $root 'VERSION'
    if (Test-Path $vf) { $Version = (Get-Content $vf -Raw -Encoding UTF8).Trim() } else { $Version = '1.0.0' }
}
$stage = Join-Path $distRoot "PerfCapture-$Version"

Write-Host "== PerfCapture 打包 $Version ==" -ForegroundColor Cyan
Write-Host "  源: $root"
Write-Host "  目标: $stage"

# ---------- 1. 必需文件校验（缺一个就停，避免产出半成品） ----------
$required = @(
    'src\PerfCapture.ps1',
    'src\engine\Measure-GamePerf.ps1',
    'ui\index.html',
    'ui\css\tokens.css',
    'ui\css\updates.css',
    'ui\js\main.js',
    'ui\js\updates-data.js',
    'ui\js\updates.js',
    'ui\js\i18n.js'
    'assets\app-icon.ico',
    'lib\Microsoft.Web.WebView2.Core.dll',
    'lib\Microsoft.Web.WebView2.WinForms.dll',
    'lib\WebView2Loader.dll',
    'tools\presentmon.exe',
    'deps\deps.json',
    'deps-inbox\说明.txt',
    'capture-options.json',
    'build\launcher.cs',
    'build\setup-core.cs',
    'build\setup-ui.cs',
    'build\setup-dpi.manifest'
)
$missing = @()
foreach ($r in $required) { if (-not (Test-Path (Join-Path $root $r))) { $missing += $r } }
if ($missing.Count) {
    Write-Host "  ❌ 缺少必需文件:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "     - $_" }
    throw '打包中止：必需文件不全'
}
Write-Host "  ✅ 必需文件齐全 ($($required.Count) 项)"

# ---------- 2. 复制目录 ----------
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$dirs = 'src', 'ui', 'assets', 'lib', 'tools', 'deps', 'deps-inbox', 'tests'
# runtime\webview2 可选：
#   有 → 一起打包，真正零外部依赖
#   无 → 产物依赖系统 WebView2（Win11 自带；Win10 缺则走 deps 引导）
if (Test-Path (Join-Path $root 'runtime\webview2\msedgewebview2.exe')) {
    $dirs += 'runtime'
    Write-Host '  ℹ 检测到内置 WebView2 运行时，将一并打包' -ForegroundColor Cyan
} else {
    Write-Host '  ⚠ 未提供 runtime\webview2，产物依赖系统 WebView2（Win11 自带）' -ForegroundColor Yellow
}
foreach ($d in $dirs) {
    robocopy (Join-Path $root $d) (Join-Path $stage $d) /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "复制 $d 失败 (robocopy $LASTEXITCODE)" }
}
foreach ($f in 'PerfCapture.cmd', 'README.md', 'CHANGELOG.md', 'AGENTS.md', 'VERSION', 'capture-options.json') {
    $src = Join-Path $root $f
    if (Test-Path $src) { Copy-Item $src $stage -Force }
}
# 报告目录留空壳，绝不打包历史数据
New-Item -ItemType Directory -Path (Join-Path $stage 'reports') -Force | Out-Null
Write-Host "  ✅ 目录复制完成"

# ---------- 3. 编译启动器 exe ----------
$csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw '找不到 csc.exe（.NET Framework 4.x 缺失）' }

$exeOut = Join-Path $stage 'PerfCapture.exe'
$ico    = Join-Path $root 'assets\app-icon.ico'
$cs     = Join-Path $buildDir 'launcher.cs'
& $csc /nologo /target:winexe /platform:anycpu "/win32icon:$ico" "/out:$exeOut" /r:System.Windows.Forms.dll $cs 2>&1 | ForEach-Object { "     $_" }
if (-not (Test-Path $exeOut)) { throw 'PerfCapture.exe 编译失败' }
Write-Host "  ✅ 启动器已编译: $([math]::Round((Get-Item $exeOut).Length/1KB)) KB"

# ---------- 4. 绝对路径审计 ----------
$leaks = @()
foreach ($d in 'src', 'ui', 'deps') {
    Get-ChildItem (Join-Path $stage $d) -Recurse -File -Include '*.ps1', '*.js', '*.css', '*.html', '*.json' |
        ForEach-Object {
            $hit = Select-String -Path $_.FullName -Pattern 'C:\\Users\\|D:\\|E:\\' -List -ErrorAction SilentlyContinue
            if ($hit) { $leaks += $_.FullName.Substring($stage.Length + 1) }
        }
}
if ($leaks.Count) {
    Write-Host "  ⚠ 发现疑似绝对路径（需人工确认是否是文档示例）:" -ForegroundColor Yellow
    $leaks | ForEach-Object { Write-Host "     - $_" }
} else {
    Write-Host "  ✅ 无硬编码绝对路径"
}

# ---------- 5. 体积统计 ----------
$sizeMB = [math]::Round(((Get-ChildItem $stage -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Host "  ✅ 产物大小: $sizeMB MB"

# ---------- 6. 压缩 ----------
if (-not $NoZip) {
    $zip = "$stage.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Write-Host "  压缩中…"
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
    Write-Host ("  ✅ 已生成: $zip  ({0} MB)" -f [math]::Round((Get-Item $zip).Length / 1MB, 1))
}

Write-Host ''

# ---------- 7. 安装包（单 exe，内嵌 payload.zip） ----------
# 安装向导在 build\setup-core.cs + build\setup-ui.cs，用同一套 csc 编译，
# payload.zip = 上面 $stage 目录的内容（解压即安装，无需再联网）。
$setupOut = Join-Path $distRoot "PerfCapture-Setup-$Version.exe"
if (Test-Path $setupOut) { Remove-Item $setupOut -Force }
$payload = Join-Path $buildDir 'payload.zip'
if (Test-Path $payload) { Remove-Item $payload -Force }
Write-Host '  生成安装包 payload…'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $payload, [System.IO.Compression.CompressionLevel]::Optimal, $false)

$setupSrc = @((Join-Path $buildDir 'setup-core.cs'), (Join-Path $buildDir 'setup-ui.cs'))
# DPI 清单必须编进去：没它 150% 缩放时 Windows 会把整个安装窗口位图拉伸 1.5 倍（很糊），
# 而且 Application.EnableVisualStyles() 会空转（按钮退回 Win95 立体边框）。
$manifest = Join-Path $buildDir 'setup-dpi.manifest'
& $csc /nologo /target:winexe /platform:anycpu "/win32icon:$ico" "/out:$setupOut" `
    "/win32manifest:$manifest" `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.IO.Compression.dll `
    "/resource:$payload,payload.zip" @setupSrc 2>&1 | ForEach-Object { "     $_" }
if (-not (Test-Path $setupOut)) { throw '安装包编译失败' }
Remove-Item $payload -Force -ErrorAction SilentlyContinue
Write-Host ("  ✅ 安装包: $setupOut  ({0} MB)" -f [math]::Round((Get-Item $setupOut).Length / 1MB, 1))
# ---------- 9. 更新清单 + 签名（updates\latest.json 与 manifest-<版本>.json） ----------
# 清单是客户端"检查更新"的唯一依据：多源读取 → RSA 验签 → 版本比较 → 按 sha256 校验安装包。
# 私钥在 %LOCALAPPDATA%\PerfCapture\keys\，绝不进仓库；公钥硬编码在 src\app\70-Updates.ps1。
if (-not $NoManifest) {
    $updatesDir = Join-Path $root 'updates'
    if (-not (Test-Path $updatesDir)) { New-Item -ItemType Directory -Path $updatesDir -Force | Out-Null }
    $repoSlug = 'yousouyouka/PerfCapture'
    $zipOut = Join-Path $distRoot "PerfCapture-$Version.zip"
    $relDate = if ($ReleaseDate) { $ReleaseDate } else { Get-Date -Format 'yyyy-MM-dd' }

    function Get-AssetEntry([string]$file, [string]$kind) {
        $name = Split-Path $file -Leaf
        return [ordered]@{
            kind = $kind
            name = $name
            size = (Get-Item -LiteralPath $file).Length
            sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
            urls = (Get-AssetUrls $name)
        }
    }

    # 资产下载源：jsDelivr 会回 403 Forbidden 拒绝分发 .exe（实测 2026-11-15），
    # 所以可执行文件直接从 raw 起排，别把死链放第一位浪费一次超时。
    function Get-AssetUrls([string]$name) {
        $raw = "https://raw.githubusercontent.com/$repoSlug/updates/bin/$name"
        $proxy = "https://ghproxy.net/https://github.com/$repoSlug/releases/download/v$Version/$name"
        $rel = "https://github.com/$repoSlug/releases/download/v$Version/$name"
        $jsd = "https://cdn.jsdelivr.net/gh/$repoSlug@updates/bin/$name"
        if ($name -match '\.exe$') { return @($raw, $proxy, $rel) }
        return @($jsd, $raw, $proxy, $rel)
    }

    # 更新说明：取 CHANGELOG 里该版本标题
    $notesZh = ''
    try {
        $cl = Get-Content (Join-Path $stage 'CHANGELOG.md') -Raw -Encoding UTF8
        $m = [regex]::Match($cl, ("(?m)^##\s+" + [regex]::Escape($Version) + "\s+—\s+\S+（([^）]+)）"))
        if ($m.Success) { $notesZh = $m.Groups[1].Value }
    } catch { }
    if (-not $notesZh) { $notesZh = "发布 $Version" }

    # serial 单调递增（防重放：拿旧清单冒充新版）
    $serial = 1
    $latestPath = Join-Path $updatesDir 'latest.json'
    if (Test-Path $latestPath) {
        try {
            $prev = Get-Content $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($prev.serial) { $serial = [int]$prev.serial + 1 }
        } catch { }
    }

    $assets = @()
    if (Test-Path $setupOut) { $assets += Get-AssetEntry $setupOut 'setup' }
    if (Test-Path $zipOut) { $assets += Get-AssetEntry $zipOut 'zip' }

    $manifestObj = [ordered]@{
        schema = 1
        app = 'PerfCapture'
        channel = 'stable'
        version = $Version
        date = $relDate
        serial = $serial
        notes = [ordered]@{ zh = $notesZh; en = 'See the release notes in the app (What''s new).'; ja = 'アプリ内の更新情報をご覧ください。' }
        assets = $assets
    }
    $json = ($manifestObj | ConvertTo-Json -Depth 6)
    $enc = New-Object Text.UTF8Encoding($false)
    $versionPath = Join-Path $updatesDir "manifest-$Version.json"
    [IO.File]::WriteAllText($versionPath, $json, $enc)
    [IO.File]::WriteAllText($latestPath, $json, $enc)

    $privKey = Join-Path $env:LOCALAPPDATA 'PerfCapture\keys\update-signing-private.xml'
    if (Test-Path $privKey) {
        & (Join-Path $buildDir 'sign-manifest.ps1') -Path @($versionPath, $latestPath) | ForEach-Object { "     $_" }
        Write-Host ("  ✅ 更新清单已生成并签名（版本 $Version · serial $serial · 日期 $relDate）")
    } else {
        Write-Host "  ⚠ 未找到签名私钥，清单未签名：$privKey" -ForegroundColor Yellow
        Write-Host '     未签名的清单会被客户端拒绝（验签失败）。发布前务必先签名。' -ForegroundColor Yellow
    }
}
Write-Host '== 打包完成 ==' -ForegroundColor Green
Write-Host "  绿色目录: $stage"
Write-Host '  直接双击 PerfCapture.exe 即可运行（首次会弹一次 UAC）'
