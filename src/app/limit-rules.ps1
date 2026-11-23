# 限制类型判读（2.1.17 / F4-1；纯函数 · 无副作用）
#
# 目的：把「降频了」说成「为什么降」——结合 GPU 限流原因占比、温度、功耗上限与
#       CPU 固件限速事件，判成 thermal / power / driver / unobserved / indistinct。
#
# 设计原则：
#   - **纯函数、无 IO**：探针构造数值直接验证，不跑采集、不读事件日志。
#   - **NVML 直接证据优先**：sw_thermal / hw_thermal / sw_power_cap / hw_power_brake /
#     app_clocks 是驱动明确报告的限制原因；CPU Event 37 只记录「发生过固件限速」，
#     Group 编号语义因厂商而异，不解析、不猜测，只作为辅助信号。
#   - **多证据冲突 → indistinct**：热与功耗同时触发且温度/功耗辅助信号不能分辨主因时，
#     输出「无法区分」，不挑一个好看的结论。
#   - **数据不可用 → indistinct，不是 unobserved**：「没有观察到限制」和
#     「根本没看」是两件事，后者不能说成前者。
#   - **unknown 不冒充 ok**：NA / 空 / 非数字一律按缺数据处理。
#
# 与《后续功能规划与优先级.md》§3.5（F4-1）对应。

$script:LimitActivePct    = 5.0    # 限流原因占比低于此值视为偶发，不算确实触发
$script:LimitGpuHotC      = 80.0   # GPU 峰值温度达到此值算「确实热」
$script:LimitCpuHotC      = 90.0   # CPU 峰值温度达到此值算「确实热」
$script:LimitPowerNearPct = 90.0   # 峰值功耗达到上限的此比例算「贴近功耗墙」

function ConvertTo-LimitNum($v) {
    if ($null -eq $v) { return $null }
    $s = ([string]$v).Trim()
    if (-not $s -or $s -eq 'NA' -or $s -eq '-') { return $null }
    $d = 0.0
    # 写出侧用 InvariantCulture（见下方 evidence），解析侧必须一致：
    # 在小数点为逗号等区域，单参数 TryParse 会把 "12.5" 读错或直接失败。
    if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

function Get-LimitPct($Throttle, [string]$Key) {
    if ($null -eq $Throttle) { return $null }
    return ConvertTo-LimitNum $Throttle[$Key]
}

# 返回 ordered hashtable：
#   kind         thermal / power / driver / unobserved / indistinct
#   reason_code  gpuThermal / cpuThermal / gpuPower / appClocks / mixed / mixedIncomplete /
#                mixedThermal / mixedPower / cpuEventUnknown / hwSlowdown / none / noData
#   evidence[]   { metric, name, value } —— 全部来自本次采集的原始数值，缺的不写
function Get-LimitType {
    param(
        $Throttle = $null,
        $GpuTempMaxC = $null,
        $GpuPowerMaxW = $null,
        $GpuLimitW = $null,
        $CpuTempMaxC = $null,
        [string]$CpuThrottleState = '',
        $CpuThrottleCount = 0,
        [bool]$GpuThrottleAvailable = $false,
        [bool]$CpuTempAvailable = $false
    )

    $swTh = Get-LimitPct $Throttle 'sw_thermal'
    $hwTh = Get-LimitPct $Throttle 'hw_thermal'
    $swPw = Get-LimitPct $Throttle 'sw_power_cap'
    $hwPw = Get-LimitPct $Throttle 'hw_power_brake'
    $appCk = Get-LimitPct $Throttle 'app_clocks'
    $hwSl = Get-LimitPct $Throttle 'hw_slowdown'

    $gpuTemp = ConvertTo-LimitNum $GpuTempMaxC
    $gpuPwr = ConvertTo-LimitNum $GpuPowerMaxW
    $limitW = ConvertTo-LimitNum $GpuLimitW
    $cpuTemp = ConvertTo-LimitNum $CpuTempMaxC
    $cpuCnt = ConvertTo-LimitNum $CpuThrottleCount
    if ($null -eq $cpuCnt) { $cpuCnt = 0.0 }

    $thermal = (($null -ne $swTh -and $swTh -ge $script:LimitActivePct) -or
                ($null -ne $hwTh -and $hwTh -ge $script:LimitActivePct))
    $power = (($null -ne $swPw -and $swPw -ge $script:LimitActivePct) -or
              ($null -ne $hwPw -and $hwPw -ge $script:LimitActivePct))
    $driver = ($null -ne $appCk -and $appCk -ge $script:LimitActivePct)
    $hwUnknown = ($null -ne $hwSl -and $hwSl -ge $script:LimitActivePct)

    $gpuHot = ($null -ne $gpuTemp -and $gpuTemp -ge $script:LimitGpuHotC)
    $gpuAtLimit = ($null -ne $gpuPwr -and $null -ne $limitW -and $limitW -gt 0 -and
                   $gpuPwr -ge ($limitW * $script:LimitPowerNearPct / 100.0))
    $cpuEvent = (([string]$CpuThrottleState) -eq 'ok' -and $cpuCnt -gt 0)
    $cpuHot = ($CpuTempAvailable -and $null -ne $cpuTemp -and $cpuTemp -ge $script:LimitCpuHotC)

    $kind = 'indistinct'
    $reason = 'noData'

    $direct = @()
    if ($thermal) { $direct += 'thermal' }
    if ($power) { $direct += 'power' }
    if ($driver) { $direct += 'driver' }

    if ($direct.Count -gt 1) {
        # 热与功耗同时触发时，只有「温度高且功耗没贴上限」或「功耗贴上限且温度不高」
        # 这两种互斥情形才能分辨。**分辨的前提是两路辅助数据都拿到**：
        # 缺温度就无从说「温度不高」，缺功耗上限就无从说「没贴上限」——
        # 把缺数据当成「没触发」会得出确定结论，这正是不猜原则要禁止的。
        if ($direct.Count -eq 2 -and $direct -contains 'thermal' -and $direct -contains 'power') {
            $canSeparate = ($null -ne $gpuTemp) -and ($null -ne $gpuPwr) -and ($null -ne $limitW) -and ($limitW -gt 0)
            if (-not $canSeparate) {
                $kind = 'indistinct'; $reason = 'mixedIncomplete'
            } elseif ($gpuHot -and -not $gpuAtLimit) {
                $kind = 'thermal'; $reason = 'mixedThermal'
            } elseif ($gpuAtLimit -and -not $gpuHot) {
                $kind = 'power'; $reason = 'mixedPower'
            } else {
                $kind = 'indistinct'; $reason = 'mixed'
            }
        } else {
            $kind = 'indistinct'; $reason = 'mixed'
        }
    } elseif ($direct.Count -eq 1) {
        $kind = $direct[0]
        $reason = switch ($kind) {
            'thermal' { 'gpuThermal' }
            'power'   { 'gpuPower' }
            'driver'  { 'appClocks' }
        }
    } elseif ($cpuEvent -and $cpuHot) {
        $kind = 'thermal'; $reason = 'cpuThermal'
    } elseif ($cpuEvent) {
        # 有固件限速但 CPU 温度不高：Event 37 的 Group 语义不解析，无法归因
        $kind = 'indistinct'; $reason = 'cpuEventUnknown'
    } elseif ($hwUnknown) {
        # NVML 只报「硬件降频」，没有给出原因位，不猜
        $kind = 'indistinct'; $reason = 'hwSlowdown'
    } elseif ($GpuThrottleAvailable -or ([string]$CpuThrottleState) -eq 'ok') {
        $kind = 'unobserved'; $reason = 'none'
    } else {
        $kind = 'indistinct'; $reason = 'noData'
    }

    $ev = New-Object System.Collections.ArrayList
    $thrNames = [ordered]@{
        sw_thermal     = @('throttle.sw_thermal', '温度墙（软）')
        hw_thermal     = @('throttle.hw_thermal', '温度墙（硬）')
        sw_power_cap   = @('throttle.sw_power_cap', '功耗墙')
        hw_power_brake = @('throttle.hw_power_brake', '功耗刹车')
        app_clocks     = @('throttle.app_clocks', '应用锁频')
        hw_slowdown    = @('throttle.hw_slowdown', '硬件降频')
    }
    foreach ($k in $thrNames.Keys) {
        $v = Get-LimitPct $Throttle $k
        if ($null -eq $v) { continue }
        [void]$ev.Add([ordered]@{
            metric = $thrNames[$k][0]
            name   = $thrNames[$k][1]
            value  = ([string]::Format([cultureinfo]::InvariantCulture, '{0:0.0}', $v)) + ' %'
        })
    }
    if ($null -ne $gpuTemp) {
        [void]$ev.Add([ordered]@{ metric = 'gpu.temp'; name = 'GPU 峰值温度';
            value = ([string]::Format([cultureinfo]::InvariantCulture, '{0:0.0}', $gpuTemp)) + ' °C' })
    }
    if ($null -ne $gpuPwr) {
        [void]$ev.Add([ordered]@{ metric = 'gpu.power'; name = 'GPU 峰值功耗';
            value = ([string]::Format([cultureinfo]::InvariantCulture, '{0:0.0}', $gpuPwr)) + ' W' })
    }
    if ($null -ne $limitW) {
        [void]$ev.Add([ordered]@{ metric = 'env.gpuPowerLimit'; name = 'GPU 功耗上限';
            value = ([string]::Format([cultureinfo]::InvariantCulture, '{0:0.0}', $limitW)) + ' W' })
    }
    if ($CpuTempAvailable -and $null -ne $cpuTemp) {
        [void]$ev.Add([ordered]@{ metric = 'cpu.temp'; name = 'CPU 峰值温度';
            value = ([string]::Format([cultureinfo]::InvariantCulture, '{0:0.0}', $cpuTemp)) + ' °C' })
    }
    if (([string]$CpuThrottleState) -eq 'ok') {
        [void]$ev.Add([ordered]@{ metric = 'cpu.throttle'; name = 'CPU 固件限速';
            value = ([string]::Format([cultureinfo]::InvariantCulture, '{0:0}', $cpuCnt)) + ' 条' })
    }

    return [ordered]@{
        kind        = $kind
        reason_code = $reason
        evidence    = @($ev.ToArray())
    }
}
