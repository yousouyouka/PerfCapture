# 限制类型判读探针（2.1.17 / F4-1）
#
# 只验证 limit-rules.ps1 的判定：构造限流占比、温度、功耗与事件状态，不跑采集。
# 重点：四类结论各能对上、「无法区分」优先、数据不足不说成「未观察到限制」。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-limit-rules.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$mod = Join-Path $root 'src\app\limit-rules.ps1'

$script:fail = 0
$script:pass = 0
function Assert($cond, $name, $detail) {
    if ($cond) { $script:pass++; Write-Host ('  OK   ' + $name) -ForegroundColor DarkGray }
    else { $script:fail++; Write-Host ('  FAIL ' + $name + '  ' + $detail) -ForegroundColor Red }
}

if (-not (Test-Path -LiteralPath $mod)) { Write-Host '缺少 limit-rules.ps1' -ForegroundColor Red; exit 1 }
. $mod
if (-not (Get-Command Get-LimitType -ErrorAction SilentlyContinue)) {
    Write-Host 'limit-rules.ps1 未导出 Get-LimitType' -ForegroundColor Red; exit 1
}

function New-Throttle([hashtable]$pairs) {
    $h = [ordered]@{}
    foreach ($k in $pairs.Keys) { $h[$k] = $pairs[$k] }
    return $h
}
function Invoke($thr, $gpuT = $null, $gpuP = $null, $limW = $null, $cpuT = $null,
                $cpuState = 'ok', $cpuCount = 0, $gpuOk = $true, $cpuTOk = $false) {
    return Get-LimitType -Throttle $thr -GpuTempMaxC $gpuT -GpuPowerMaxW $gpuP -GpuLimitW $limW `
        -CpuTempMaxC $cpuT -CpuThrottleState $cpuState -CpuThrottleCount $cpuCount `
        -GpuThrottleAvailable $gpuOk -CpuTempAvailable $cpuTOk
}

Write-Host '== 1. 四类结论各造一组数据 ==' -ForegroundColor Cyan
$r = Invoke (New-Throttle @{ sw_thermal = 42.0 }) -gpuT 86
Assert ($r.kind -eq 'thermal') 'GPU 热降频 → thermal' ('实际 ' + $r.kind)
Assert ($r.reason_code -eq 'gpuThermal') '原因码 gpuThermal' ('实际 ' + $r.reason_code)

$r = Invoke (New-Throttle @{ sw_power_cap = 31.5 }) -gpuP 245 -limW 250
Assert ($r.kind -eq 'power') 'GPU 功耗墙 → power' ('实际 ' + $r.kind)
Assert ($r.reason_code -eq 'gpuPower') '原因码 gpuPower' ('实际 ' + $r.reason_code)

$r = Invoke (New-Throttle @{ app_clocks = 80.0 })
Assert ($r.kind -eq 'driver') '应用锁频 → driver' ('实际 ' + $r.kind)
Assert ($r.reason_code -eq 'appClocks') '原因码 appClocks' ('实际 ' + $r.reason_code)

$r = Invoke (New-Throttle @{})
Assert ($r.kind -eq 'unobserved') '有数据、无限制 → unobserved' ('实际 ' + $r.kind)

Write-Host '== 2. 多证据冲突：不猜主因 ==' -ForegroundColor Cyan
$r = Invoke (New-Throttle @{ sw_thermal = 40; sw_power_cap = 35 }) -gpuT 70 -gpuP 120 -limW 250
Assert ($r.kind -eq 'indistinct') '热+功耗触发但辅助信号不互斥 → indistinct' ('实际 ' + $r.kind)
Assert ($r.reason_code -eq 'mixed') '原因码 mixed' ('实际 ' + $r.reason_code)

$r = Invoke (New-Throttle @{ sw_thermal = 40; app_clocks = 60 }) -gpuT 85
Assert ($r.kind -eq 'indistinct') '热+应用锁频 → indistinct' ('实际 ' + $r.kind)

Write-Host '== 3. 多证据但辅助信号可分辨 ==' -ForegroundColor Cyan
$r = Invoke (New-Throttle @{ sw_thermal = 40; sw_power_cap = 35 }) -gpuT 88 -gpuP 120 -limW 250
Assert ($r.kind -eq 'thermal') '温度高但功耗远离上限 → thermal' ('实际 ' + $r.kind)
Assert ($r.reason_code -eq 'mixedThermal') '原因码 mixedThermal' ('实际 ' + $r.reason_code)

$r = Invoke (New-Throttle @{ sw_thermal = 40; sw_power_cap = 35 }) -gpuT 62 -gpuP 248 -limW 250
Assert ($r.kind -eq 'power') '功耗贴上限但温度不高 → power' ('实际 ' + $r.kind)
Assert ($r.reason_code -eq 'mixedPower') '原因码 mixedPower' ('实际 ' + $r.reason_code)

Write-Host '== 4. CPU Event 37 只作辅助，不解析 Group 语义 ==' -ForegroundColor Cyan
$r = Invoke (New-Throttle @{}) -cpuT 94 -cpuState ok -cpuCount 3 -cpuTOk $true
Assert ($r.kind -eq 'thermal') '固件限速 + CPU 高温 → thermal' ('实际 ' + $r.kind)
Assert ($r.reason_code -eq 'cpuThermal') '原因码 cpuThermal' ('实际 ' + $r.reason_code)

$r = Invoke (New-Throttle @{}) -cpuT 62 -cpuState ok -cpuCount 3 -cpuTOk $true
Assert ($r.kind -eq 'indistinct') '有固件限速但温度不高 → indistinct（不猜原因）' ('实际 ' + $r.kind)
Assert ($r.reason_code -eq 'cpuEventUnknown') '原因码 cpuEventUnknown' ('实际 ' + $r.reason_code)

Write-Host '== 5. 数据不可用 / 原因不明：必须说无法区分 ==' -ForegroundColor Cyan
$r = Invoke (New-Throttle @{ hw_slowdown = 90 })
Assert ($r.kind -eq 'indistinct') '硬件降频无原因位 → indistinct' ('实际 ' + $r.kind)
Assert ($r.reason_code -eq 'hwSlowdown') '原因码 hwSlowdown' ('实际 ' + $r.reason_code)

$r = Get-LimitType -Throttle $null -GpuThrottleAvailable $false -CpuThrottleState unavailable
Assert ($r.kind -eq 'indistinct') '两路数据都不可用 → indistinct（不是 unobserved）' ('实际 ' + $r.kind)
Assert ($r.reason_code -eq 'noData') '原因码 noData' ('实际 ' + $r.reason_code)

$r = Invoke (New-Throttle @{}) -cpuState skipped
Assert ($r.kind -eq 'unobserved') 'GPU 数据可用即可说 unobserved' ('实际 ' + $r.kind)

Write-Host '== 6. 阈值边界与 NA 处理 ==' -ForegroundColor Cyan
$r = Invoke (New-Throttle @{ sw_thermal = 5.0 })
Assert ($r.kind -eq 'thermal') '恰好 5% 算触发' ('实际 ' + $r.kind)
$r = Invoke (New-Throttle @{ sw_thermal = 4.9 })
Assert ($r.kind -eq 'unobserved') '4.9% 是偶发，不触发' ('实际 ' + $r.kind)
$r = Invoke (New-Throttle @{ sw_thermal = 'NA'; sw_power_cap = 20 })
Assert ($r.kind -eq 'power') 'NA 跳过，不冒充 0' ('实际 ' + $r.kind)
$r = Invoke (New-Throttle @{ sw_thermal = 'oops' })
Assert ($r.kind -eq 'unobserved') '非数字跳过' ('实际 ' + $r.kind)

Write-Host '== 7. evidence 必须有原始数值，不是只有结论 ==' -ForegroundColor Cyan
$r = Invoke (New-Throttle @{ sw_thermal = 42.0; sw_power_cap = 'NA' }) -gpuT 86 -gpuP 120 -limW 250 -cpuT 70 -cpuTOk $true -cpuState ok -cpuCount 2
$ev = @($r.evidence)
Assert ($ev.Count -ge 5) '列出全部可用原始数值' ('实际 ' + $ev.Count)
$swThEv = @($ev | Where-Object { $_.metric -eq 'throttle.sw_thermal' })
Assert ($swThEv.Count -eq 1 -and $swThEv[0].value -eq '42.0 %') '热降频原始占比在依据里' ('实际 ' + $swThEv[0].value)
$zero = @($ev | Where-Object { $_.metric -eq 'throttle.sw_power_cap' })
Assert ($zero.Count -eq 0) 'NA 项不写进依据（不冒充未触发）' ('实际 ' + $zero.Count)
$gpuEv = @($ev | Where-Object { $_.metric -eq 'gpu.temp' })
Assert ($gpuEv.Count -eq 1 -and $gpuEv[0].value -eq '86.0 °C') 'GPU 峰值温度在依据里' ('实际 ' + $gpuEv[0].value)

Write-Host ''
Write-Host ("结果: " + $script:pass + " 通过 / " + $script:fail + " 失败") -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
exit 0
