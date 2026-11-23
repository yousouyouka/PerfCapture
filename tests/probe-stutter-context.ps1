# 卡顿时刻上下文探针（2.1.16 / F2-1）
#
# 只验证 stutter-context.ps1 的对齐与聚合：构造帧时间与传感器样本，不跑采集。
# 重点：位置换算、窗口大小、NA 跳过、Top 截断、各种「为什么没有」的原因码。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-stutter-context.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$mod = Join-Path $root 'src\app\stutter-context.ps1'

$script:fail = 0
$script:pass = 0
function Assert($cond, $name, $detail) {
    if ($cond) { $script:pass++; Write-Host ('  OK   ' + $name) -ForegroundColor DarkGray }
    else { $script:fail++; Write-Host ('  FAIL ' + $name + '  ' + $detail) -ForegroundColor Red }
}

if (-not (Test-Path -LiteralPath $mod)) { Write-Host '缺少 stutter-context.ps1' -ForegroundColor Red; exit 1 }
. $mod
if (-not (Get-Command Get-StutterContext -ErrorAction SilentlyContinue)) {
    Write-Host 'stutter-context.ps1 未导出 Get-StutterContext' -ForegroundColor Red; exit 1
}

# 造数据：600 帧 × 16.7ms ≈ 10.02s；11 个传感器样本 ≈ 每秒一个
function New-Frames([int]$n = 600) {
    $a = New-Object 'double[]' $n
    for ($i = 0; $i -lt $n; $i++) { $a[$i] = 16.7 }
    return $a
}
function New-Sensors([int]$n = 11) {
    $s = @()
    for ($i = 0; $i -lt $n; $i++) {
        $s += [pscustomobject]@{
            gpu_util_pct = '95'; gpu_temp_c = [string](60 + $i); gpu_mem_used_mb = '6000'
            gpu_power_w = '120'; cpu_util_pct = '40'; cpu_temp_c = '75'; cpu_pkg_w = '45'
        }
    }
    return $s
}

Write-Host '== 1. 单段卡顿：位置与窗口 ==' -ForegroundColor Cyan
$ft = New-Frames
$sens = New-Sensors
$seg = @([pscustomobject]@{ start = 300; frames = 1; ms = 200.0 })
$r = Get-StutterContext -Segments $seg -FrameTimes $ft -Sensors $sens -WindowSec 2 -Top 5
Assert (@($r.items).Count -eq 1) '返回 1 段' ('实际 ' + @($r.items).Count)
$it = @($r.items)[0]
Assert ([math]::Abs([double]$it.at_pct - 50.0) -le 1.0) 'at_pct ≈ 50%（第 300 帧在中间）' ('实际 ' + $it.at_pct)
Assert ($it.samples -eq 5) '窗口 5 个样本（±2 秒 ≈ ±2 个采样）' ('实际 ' + $it.samples)
Assert ([math]::Abs([double]$r.tolerance_seconds - 1.0) -le 0.2) '容差 ≈ 1 秒（采样间隔）' ('实际 ' + $r.tolerance_seconds)
Assert ($it.avg.gpu_temp -eq 65) '窗口平均温度 = 63..67 的均值 65' ('实际 ' + $it.avg.gpu_temp)
Assert ($it.peak.gpu_temp -eq 67) '窗口峰值 67' ('实际 ' + $it.peak.gpu_temp)
Assert ($it.at.gpu_temp -eq 65) '「当时」取中心样本 65' ('实际 ' + $it.at.gpu_temp)

Write-Host '== 2. 位置单调：越靠后的卡顿 at_pct 越大 ==' -ForegroundColor Cyan
$segs = @(
    [pscustomobject]@{ start = 100; frames = 1; ms = 300.0 },
    [pscustomobject]@{ start = 500; frames = 2; ms = 200.0 }
)
$r2 = Get-StutterContext -Segments $segs -FrameTimes $ft -Sensors $sens
$p1 = [double]@($r2.items)[0].at_pct
$p2 = [double]@($r2.items)[1].at_pct
Assert ($p1 -lt $p2) '两段按位置递增' ($p1.ToString() + ' vs ' + $p2.ToString())
Assert ([math]::Abs($p1 - 16.7) -le 2.0) '第一段 ≈ 100/600' ('实际 ' + $p1)

Write-Host '== 3. NA 不参与平均（不当 0）==' -ForegroundColor Cyan
$sensNa = New-Sensors
$sensNa[4].gpu_temp_c = 'NA'      # 索引 4 的温度是 64；窗口 63..67 去掉它
$r3 = Get-StutterContext -Segments $seg -FrameTimes $ft -Sensors $sensNa
$avg3 = [double]@($r3.items)[0].avg.gpu_temp
# 去掉 64 后：(63+65+66+67)/4 = 65.25 → 65.2；若把 NA 当 0 会是 52.2
Assert ($avg3 -eq 65.2) '跳过 NA 后均值 65.2（不是按 0 拉低到 52.2）' ('实际 ' + $avg3)

Write-Host '== 4. Top 截断 ==' -ForegroundColor Cyan
$many = @()
for ($i = 1; $i -le 8; $i++) { $many += [pscustomobject]@{ start = ($i * 50); frames = 1; ms = (300.0 - $i) } }
$r4 = Get-StutterContext -Segments $many -FrameTimes $ft -Sensors $sens -Top 5
Assert (@($r4.items).Count -eq 5) '只返回 Top 5' ('实际 ' + @($r4.items).Count)

Write-Host '== 5. 原因码：没有东西可算时如实说明 ==' -ForegroundColor Cyan
$r5 = Get-StutterContext -Segments $seg -FrameTimes $ft -Sensors @()
Assert ($r5.reason -eq 'noSensors') '无传感器 → noSensors' ('实际 ' + $r5.reason)
$r6 = Get-StutterContext -Segments @() -FrameTimes $ft -Sensors $sens
Assert ($r6.reason -eq 'noStutter') '无卡顿 → noStutter' ('实际 ' + $r6.reason)
$r7 = Get-StutterContext -Segments $seg -FrameTimes @(16.7) -Sensors $sens
Assert ($r7.reason -eq 'noFrames') '帧数不足 → noFrames' ('实际 ' + $r7.reason)

Write-Host '== 6. 边界：卡顿在第 0 帧 / 最后一帧不越界 ==' -ForegroundColor Cyan
$r8 = Get-StutterContext -Segments @([pscustomobject]@{ start = 0; frames = 1; ms = 200 }) -FrameTimes $ft -Sensors $sens
Assert (@($r8.items).Count -eq 1) '第 0 帧仍能算出结果' ('实际 ' + @($r8.items).Count)
Assert (@($r8.items)[0].samples -ge 1) '窗口至少 1 个样本' ('实际 ' + @($r8.items)[0].samples)
$r9 = Get-StutterContext -Segments @([pscustomobject]@{ start = 9999; frames = 1; ms = 200 }) -FrameTimes $ft -Sensors $sens
Assert (@($r9.items).Count -eq 1) '越界起点被夹到最后帧，不报错' ('实际 ' + @($r9.items).Count)

Write-Host ''
if ($script:fail -gt 0) {
    Write-Host ('== 失败 ' + $script:fail + ' 项 / 通过 ' + $script:pass + ' 项 ==') -ForegroundColor Red
    exit 1
}
Write-Host ('== 通过 ' + $script:pass + ' 项 ==') -ForegroundColor Green
exit 0
