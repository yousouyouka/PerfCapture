# 卡顿时刻上下文（2.1.16 / F2-1）
#
# 目的：回答「卡的那一帧，机器在干什么」——把 Top N 卡顿段与传感器样本对齐，
#       给出该时刻前后 ±N 秒的 GPU/CPU 占用、温度、显存、功耗。
#
# 设计原则：
#   - **纯函数、无 IO**：探针可以构造帧时间与样本数组直接验证，不跑采集。
#   - 两条数据流（逐帧 / 传感器）**不同源**，没有共同时间戳，因此按「采集进度比例」对齐：
#     卡顿帧之前的累计帧时间 / 总帧时间 → 映射到传感器样本下标。
#     这只保证统计意义上的位置，误差约一个采样间隔；报告必须写明容差，不许说成「精确对齐」。
#   - 样本里 'NA' / 空 / 非数字一律跳过，不做插值、不补值。
#
# 与《后续功能规划与优先级.md》§3.3（F2-1）对应。

$script:StutterCtxWindowSec = 2.0
$script:StutterCtxTop = 5

# 采样列 → 输出字段名。只取这些，避免把整行塞进报告。
$script:StutterCtxFields = @(
    @{ col = 'gpu_util_pct'; key = 'gpu_util' },
    @{ col = 'gpu_temp_c'; key = 'gpu_temp' },
    @{ col = 'gpu_mem_used_mb'; key = 'vram_mb' },
    @{ col = 'gpu_power_w'; key = 'gpu_power' },
    @{ col = 'cpu_util_pct'; key = 'cpu_util' },
    @{ col = 'cpu_temp_c'; key = 'cpu_temp' },
    @{ col = 'cpu_pkg_w'; key = 'cpu_pkg' }
)

function ConvertTo-StutterNum($v) {
    if ($null -eq $v) { return $null }
    $s = ([string]$v).Trim()
    if (-not $s -or $s -eq 'NA') { return $null }
    $d = 0.0
    if ([double]::TryParse($s, [ref]$d)) { return $d }
    return $null
}

# 返回：
#   window_seconds   窗口半宽（±N 秒）
#   tolerance_seconds 对齐误差上界（≈一个采样间隔）
#   items[]          每项：start_frame / frames / ms / at_pct / samples / at{...} / avg{...} / peak{...}
#   reason           没有可算的东西时的原因码（noFrames / noSensors / noStutter）
function Get-StutterContext {
    param(
        $Segments,
        $FrameTimes,
        $Sensors,
        [double]$WindowSec = $script:StutterCtxWindowSec,
        [int]$Top = $script:StutterCtxTop
    )

    $out = [ordered]@{
        window_seconds    = $WindowSec
        tolerance_seconds = $null
        items             = @()
        reason            = ''
    }

    $ft = @($FrameTimes | ForEach-Object { ConvertTo-StutterNum $_ } | Where-Object { $null -ne $_ -and $_ -ge 0 })
    $rows = @($Sensors)
    if ($ft.Count -lt 2) { $out.reason = 'noFrames'; return $out }
    if ($rows.Count -lt 2) { $out.reason = 'noSensors'; return $out }
    $segs = @($Segments)
    if ($segs.Count -eq 0) { $out.reason = 'noStutter'; return $out }

    # 累计帧时间（ms）与总时长：卡顿段起点之前已经过了多少毫秒
    $totalMs = 0.0
    $cum = New-Object 'double[]' $ft.Count
    for ($i = 0; $i -lt $ft.Count; $i++) {
        $cum[$i] = $totalMs
        $totalMs += [double]$ft[$i]
    }
    if ($totalMs -le 0) { $out.reason = 'noFrames'; return $out }

    # 采样间隔（按「总时长 / 间隔数」估）：作为容差与窗口宽度换算依据
    $intervalMs = $totalMs / [double]($rows.Count - 1)
    $out.tolerance_seconds = [math]::Round($intervalMs / 1000.0, 1)
    $half = [math]::Max(1, [int][math]::Round(($WindowSec * 1000.0) / [math]::Max(1.0, $intervalMs)))

    $items = New-Object System.Collections.ArrayList
    foreach ($s in ($segs | Select-Object -First $Top)) {
        $startFrame = 0
        try { $startFrame = [int]$s.start } catch { $startFrame = 0 }
        if ($startFrame -lt 0) { $startFrame = 0 }
        if ($startFrame -ge $ft.Count) { $startFrame = $ft.Count - 1 }

        $atMs = $cum[$startFrame]
        $pct = 100.0 * $atMs / $totalMs
        # 映射到传感器下标（0..n-1）
        $center = [int][math]::Round(($pct / 100.0) * ($rows.Count - 1))
        if ($center -lt 0) { $center = 0 }
        if ($center -gt ($rows.Count - 1)) { $center = $rows.Count - 1 }

        $lo = [math]::Max(0, $center - $half)
        $hi = [math]::Min($rows.Count - 1, $center + $half)

        # 窗口内逐字段求平均与峰值；「卡顿当时」取中心样本
        $avg = [ordered]@{}
        $peak = [ordered]@{}
        $at = [ordered]@{}
        foreach ($f in $script:StutterCtxFields) {
            $sum = 0.0; $n = 0; $mx = $null
            for ($r = $lo; $r -le $hi; $r++) {
                $v = ConvertTo-StutterNum $rows[$r].($f.col)
                if ($null -eq $v) { continue }
                $sum += $v; $n++
                if ($null -eq $mx -or $v -gt $mx) { $mx = $v }
            }
            if ($n -gt 0) {
                $digits = if ($f.key -in @('vram_mb')) { 0 } else { 1 }
                $avg[$f.key] = [math]::Round($sum / $n, $digits)
                $peak[$f.key] = [math]::Round($mx, $digits)
            } else {
                $avg[$f.key] = $null
                $peak[$f.key] = $null
            }
            $atV = ConvertTo-StutterNum $rows[$center].($f.col)
            $at[$f.key] = if ($null -eq $atV) { $null } else { [math]::Round($atV, 1) }
        }

        [void]$items.Add([ordered]@{
            start_frame = $startFrame
            frames      = [int]$s.frames
            ms          = [double]$s.ms
            at_pct      = [math]::Round($pct, 1)
            samples     = ($hi - $lo + 1)
            at          = $at
            avg         = $avg
            peak        = $peak
        })
    }

    $out.items = @($items)
    if ($items.Count -eq 0) { $out.reason = 'noStutter' }
    return $out
}
