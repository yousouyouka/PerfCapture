# 路径常量。$script:Root / $script:EntryPath 由入口设置，此处不要用 $PSScriptRoot

# $script:Root 由入口 src\PerfCapture.ps1 设置
$script:UiDir    = Join-Path $Root 'ui'
$script:AssetDir = Join-Path $Root 'assets'
$script:Engine   = (Join-Path $Root 'src\engine\Measure-GamePerf.ps1')
$script:TempDir  = Join-Path $env:TEMP 'PerfCapture'
$script:TempHtml = Join-Path $TempDir 'preview.html'
$script:LibDir   = Join-Path $Root 'lib'
$script:ToolsDir = Join-Path $Root 'tools'

# 当前版本（VERSION 文件）：检查更新要用它做比较，界面也用它显示
$script:AppVersion = '0.0.0'
try {
    $verPath = Join-Path $Root 'VERSION'
    if (Test-Path $verPath) { $script:AppVersion = (Get-Content $verPath -Raw -Encoding UTF8).Trim() }
} catch { }

# ---------- 数据目录（配置 + 报告） ----------
# 安装包会把程序装到 %LOCALAPPDATA%\Programs\PerfCapture（或用户自选目录），
# 安装目录不该承载用户数据：配置与报告统一放 %LOCALAPPDATA%\PerfCapture。
# 老版本把这两样放在安装目录里，下面做一次性迁移（只补缺，绝不覆盖已有数据）。
$script:DataDir = Join-Path $env:LOCALAPPDATA 'PerfCapture'
$script:OutDir  = Join-Path $script:DataDir 'reports'
$script:CfgPath = Join-Path $script:DataDir 'PerfCapture.settings.json'

try {
    if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    if (-not (Test-Path $script:OutDir)) { New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null }
} catch { }

$legacyCfg = Join-Path $Root 'PerfCapture.settings.json'
$legacyRep = Join-Path $Root 'reports'
try {
    if ((Test-Path $legacyCfg) -and -not (Test-Path $script:CfgPath)) {
        Copy-Item $legacyCfg $script:CfgPath -Force
    }
    if (Test-Path $legacyRep) {
        Get-ChildItem $legacyRep -File -ErrorAction SilentlyContinue | ForEach-Object {
            $dst = Join-Path $script:OutDir $_.Name
            if (-not (Test-Path $dst)) { Copy-Item $_.FullName $dst -Force }
        }
    }
} catch { }
