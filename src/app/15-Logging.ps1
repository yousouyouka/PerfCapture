# 文件日志：%LOCALAPPDATA%\PerfCapture\logs\app-YYYYMMDD.log（保留 7 天）
# UI 终端只显示用户关心的行；这里记录排障需要的一切。

$script:LogDir  = Join-Path $env:LOCALAPPDATA 'PerfCapture\logs'
$script:LogFile = Join-Path $script:LogDir ('app-' + (Get-Date -Format 'yyyyMMdd') + '.log')
try {
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
    Get-ChildItem $script:LogDir -Filter 'app-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

function Write-AppLog {
    param(
        [string]$text,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$level = 'INFO'
    )
    try {
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss.fff'), $level, $text
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch { }
}
