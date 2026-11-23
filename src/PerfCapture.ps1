# PerfCapture · 入口
# 宿主拆分在 src\app\*，采集引擎在 src\engine\Measure-GamePerf.ps1
# 约定：子文件里一律不要用 $PSScriptRoot —— dot-source 时它指向子文件自身目录。

$script:Root      = Split-Path -Parent $PSScriptRoot     # 项目根
$script:EntryPath = $PSCommandPath                        # 提权重启必须回到入口

$appDir = Join-Path $PSScriptRoot 'app'
foreach ($f in @(
    '00-Prelude.ps1',
    '05-Paths.ps1',
    '06-NetProxy.ps1',
    '10-Bootstrap.ps1',
    '15-Logging.ps1',
    '20-Settings.ps1',
    '30-Tools.ps1',
    'platform-rules.ps1',
    'vendor-sensor.ps1',
    'cpu-throttle.ps1',
    '35-Metrics.ps1',
    '40-Bridge.ps1',
    '50-Host.ps1',
    '52-Hotkeys.ps1',
    '55-Overlay.ps1',
    '60-Capture.ps1',
    '62-Reports.ps1',
    '68-UpdateWrapper.ps1',
    '70-Updates.ps1',
    'rtss-shm.ps1',
    '80-Extensions.ps1',
    '85-ExtensionProvision.ps1',
    '90-Main.ps1'
)) {
    $full = Join-Path $appDir $f
    if (-not (Test-Path $full)) { throw "缺少宿主组件: $f" }
    . $full
}
