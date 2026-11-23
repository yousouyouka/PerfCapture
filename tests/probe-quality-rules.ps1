# 采集可信度判定探针（2.1.13 / F0-1）
#
# 只验证 quality-rules.ps1 的判定表，不跑采集、不碰硬件：
# 目的是把「什么情况算什么级别」钉死，改阈值后能立刻发现行为漂移。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-quality-rules.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$mod = Join-Path $root 'src\app\quality-rules.ps1'

$script:fail = 0
$script:pass = 0
function Assert($cond, $name, $detail) {
    if ($cond) { $script:pass++; Write-Host ('  OK   ' + $name) -ForegroundColor DarkGray }
    else { $script:fail++; Write-Host ('  FAIL ' + $name + '  ' + $detail) -ForegroundColor Red }
}
function Codes($q) { return @(@($q.checks) | ForEach-Object { [string]$_.code }) }

if (-not (Test-Path -LiteralPath $mod)) { Write-Host '缺少 quality-rules.ps1' -ForegroundColor Red; exit 1 }
. $mod
if (-not (Get-Command Get-CaptureQuality -ErrorAction SilentlyContinue)) {
    Write-Host 'quality-rules.ps1 未导出 Get-CaptureQuality' -ForegroundColor Red; exit 1
}

Write-Host '== 1. 正常采集：不出任何提示（零误报是硬要求） ==' -ForegroundColor Cyan
$q = Get-CaptureQuality -Frames 6000 -EffectiveSeconds 120 -WallSeconds 120 -ForegroundPct 100 `
    -GpuRequested $true -SensorSamples 60 -GpuSamplesOk 60
Assert ($q.level -eq 'ok') '正常数据 level=ok' ('实际 ' + $q.level)
Assert (@($q.checks).Count -eq 0) '正常数据无检查项' ('实际 ' + (@($q.checks).Count))

Write-Host '== 2. 样本过少 → blocked ==' -ForegroundColor Cyan
$q = Get-CaptureQuality -Frames 120 -EffectiveSeconds 6 -WallSeconds 6 -ForegroundPct 100
Assert ($q.level -eq 'blocked') '120 帧 / 6 秒判 blocked' ('实际 ' + $q.level)
Assert ((Codes $q) -contains 'fewSamples') '含 fewSamples' (($(Codes $q) -join ','))

Write-Host '== 3. 采集中断 → blocked ==' -ForegroundColor Cyan
$q = Get-CaptureQuality -Frames 4000 -EffectiveSeconds 60 -WallSeconds 120 -Stalled $true -ForegroundPct 100
Assert ($q.level -eq 'blocked') '中断判 blocked' ('实际 ' + $q.level)
Assert ((Codes $q) -contains 'stalled') '含 stalled' (($(Codes $q) -join ','))

Write-Host '== 4. 有效时长不足 → caution ==' -ForegroundColor Cyan
$q = Get-CaptureQuality -Frames 4000 -EffectiveSeconds 60 -WallSeconds 120 -ForegroundPct 100
Assert ($q.level -eq 'caution') '覆盖率 50% 判 caution' ('实际 ' + $q.level)
Assert ((Codes $q) -contains 'partial') '含 partial' (($(Codes $q) -join ','))

Write-Host '== 5. 前台占比低 → caution ==' -ForegroundColor Cyan
$q = Get-CaptureQuality -Frames 4000 -EffectiveSeconds 110 -WallSeconds 120 -ForegroundPct 50
Assert ($q.level -eq 'caution') '前台 50% 判 caution' ('实际 ' + $q.level)
Assert ((Codes $q) -contains 'targetLost') '含 targetLost' (($(Codes $q) -join ','))

Write-Host '== 6. GPU 采样稀疏 → caution ==' -ForegroundColor Cyan
$q = Get-CaptureQuality -Frames 4000 -EffectiveSeconds 110 -WallSeconds 120 -ForegroundPct 100 `
    -GpuRequested $true -SensorSamples 10 -GpuSamplesOk 2
Assert ($q.level -eq 'caution') 'GPU 可用率 20% 判 caution' ('实际 ' + $q.level)
Assert ((Codes $q) -contains 'gpuSparse') '含 gpuSparse' (($(Codes $q) -join ','))

Write-Host '== 7. 未开 GPU 采集 → 不评估（不许写「通过」）==' -ForegroundColor Cyan
$q = Get-CaptureQuality -Frames 4000 -EffectiveSeconds 110 -WallSeconds 120 -ForegroundPct 100 `
    -GpuRequested $false -SensorSamples 10 -GpuSamplesOk 0
Assert (@($q.checks).Count -eq 0) '未请求时不出 gpuSparse' (($(Codes $q) -join ','))
Assert ($q.level -eq 'ok') '未请求其他项正常时 level=ok' ('实际 ' + $q.level)

Write-Host '== 8. 前台占比未知 → 不判 ==' -ForegroundColor Cyan
$q = Get-CaptureQuality -Frames 4000 -EffectiveSeconds 110 -WallSeconds 120 -ForegroundPct $null
Assert (-not ((Codes $q) -contains 'targetLost')) '前台未知时不出 targetLost' (($(Codes $q) -join ','))

Write-Host '== 9. 多问题叠加 → blocked 优先 ==' -ForegroundColor Cyan
$q = Get-CaptureQuality -Frames 120 -EffectiveSeconds 6 -WallSeconds 120 -ForegroundPct 40 `
    -GpuRequested $true -SensorSamples 10 -GpuSamplesOk 1
Assert ($q.level -eq 'blocked') 'blocked 优先于 caution' ('实际 ' + $q.level)
$c = Codes $q
Assert (($c -contains 'fewSamples') -and ($c -contains 'targetLost') -and ($c -contains 'gpuSparse')) '三项同时列出' ($c -join ',')

Write-Host '== 10. 边界值：正好 300 帧 / 10 秒不报警 ==' -ForegroundColor Cyan
$q = Get-CaptureQuality -Frames 300 -EffectiveSeconds 10 -WallSeconds 10 -ForegroundPct 70
Assert ($q.level -eq 'ok') '边界值判 ok（阈值是「小于」才报）' ('实际 ' + $q.level)

Write-Host ''
if ($script:fail -gt 0) {
    Write-Host ('== 失败 ' + $script:fail + ' 项 / 通过 ' + $script:pass + ' 项 ==') -ForegroundColor Red
    exit 1
}
Write-Host ('== 通过 ' + $script:pass + ' 项 ==') -ForegroundColor Green
exit 0
