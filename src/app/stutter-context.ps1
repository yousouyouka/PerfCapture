# 卡顿时刻上下文（2.1.15 / F2-1；2.1.17 修正对齐）
#
# 目的：回答「卡的那一帧，机器在干什么」——把 Top N 卡顿段与传感器样本对齐，
#       给出该时刻前后 ±N 秒的 GPU/CPU 占用、温度、显存、功耗。
#
# 设计原则：
#   - **纯函数、无 IO**：探针可以构造帧时间与样本数组直接验证，不跑采集。
#   - 两条数据流（逐帧 / 传感器）不同源，对齐分两种模式，结果里必须写明是哪一种：
#       time         传感器行带 timestamp_utc（HH:mm:ss），按采集起点换算成秒后按时间对齐，
#                    误差 ≈ 时间戳粒度（1 秒）；
#       proportional 没有可用时间戳时，退回「按采集进度比例」映射，误差 ≈ 一个采样间隔。
#   - **比例模式必须把预热算进去**：帧数组已丢弃开头 WarmupSec 秒，传感器样本却覆盖全程，
#     直接用「卡顿帧累计时间 / 帧总时长」会整体前移最多 WarmupSec 秒（默认 3–5 秒），
#     比声称的 1 秒容差大得多。比例模式一律用 (WarmupSec + 帧总时长) 作分母。
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

# 把每行 timestamp_utc（HH:mm:ss）换算成「距采集起点的秒数」。
# 任何一行解析失败就整体返回 $null —— 宁可退回比例模式，也不拿半份时间戳硬算。
# 处理跨零点：时间倒退超过 12 小时视为进入次日。
function ConvertTo-StutterElapsed($Rows, [datetime]$Start) {
    $n = @($Rows).Count
    if ($n -lt 1) { return $null }
    $out = New-Object 'double[]' $n
    $last = $null
    $dayAdd = 0
    for ($i = 0; $i -lt $n; $i++) {
        $ts = [datetime]::MinValue
        $raw = [string]$Rows[$i].timestamp_utc
        if (-not $raw) { return $null }
        if (-not [datetime]::TryParse($raw, [ref]$ts)) { return $null }
        $t = $Start.Date.Add($ts.TimeOfDay).AddDays($dayAdd)
        if ($null -ne $last -and $t -lt $last.AddHours(-12)) {
            $dayAdd++
            $t = $t.AddDays(1)
        }
        $last = $t
        $out[$i] = ($t - $Start).TotalSeconds
    }
    return , $out
}

# 返回：
#   window_seconds    窗口半宽（±N 秒）
#   alignment         time / proportional（报告文案据此选择）
#   tolerance_seconds 对齐误差上界
#   items[]           start_frame / frames / ms / at_pct / at_elapsed_s / samples / at{...} / avg{...} / peak{...}
#   reason            没有可算的东西时的原因码（noFrames / noSensors / noStutter）
#
# at_pct 是**图上的位置**（相对已去掉预热的分析窗口），与曲线 x 轴一致；
# 传感器定位用另一套时间（at_elapsed_s），两者不要混用。
function Get-StutterContext {
    param(
        $Segments,
        $FrameTimes,
        $Sensors,
        [double]$WindowSec = $script:StutterCtxWindowSec,
        [int]$Top = $script:StutterCtxTop,
        [datetime]$CaptureStart = [datetime]::MinValue,
        [double]$WarmupSec = 0
    )

    $out = [ordered]@{
        window_seconds    = $WindowSec
        alignment         = ''
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

    # 累计帧时间（ms）：卡顿段起点之前已经过了多少毫秒（相对分析窗口起点）
    $totalMs = 0.0
    $cum = New-Object 'double[]' $ft.Count
    for ($i = 0; $i -lt $ft.Count; $i++) {
        $cum[$i] = $totalMs
        $totalMs += [double]$ft[$i]
    }
    if ($totalMs -le 0) { $out.reason = 'noFrames'; return $out }

    # 时间对齐可用就用时间；否则用比例（分母含预热）
    $elapsed = $null
    if ($CaptureStart -ne [datetime]::MinValue) { $elapsed = ConvertTo-StutterElapsed $rows $CaptureStart }
    $useTime = ($null -ne $elapsed)
    if ($useTime) {
        $out.alignment = 'time'
        $out.tolerance_seconds = 1.0        # 时间戳只到整秒
        $intervalMs = 1000.0
    } else {
        $out.alignment = 'proportional'
        $spanMs = ($WarmupSec * 1000.0) + $totalMs
        $intervalMs = $spanMs / [double]($rows.Count - 1)
        $out.tolerance_seconds = [math]::Round($intervalMs / 1000.0, 1)
    }
    $half = [math]::Max(1, [int][math]::Round(($WindowSec * 1000.0) / [math]::Max(1.0, $intervalMs)))

    $items = New-Object System.Collections.ArrayList
    foreach ($s in ($segs | Select-Object -First $Top)) {
        $startFrame = 0
        try { $startFrame = [int]$s.start } catch { $startFrame = 0 }
        if ($startFrame -lt 0) { $startFrame = 0 }
        if ($startFrame -ge $ft.Count) { $startFrame = $ft.Count - 1 }

        $atMs = $cum[$startFrame]
        $atPct = 100.0 * $atMs / $totalMs            # 图上位置（分析窗口内）
        $atElapsed = $WarmupSec + ($atMs / 1000.0)   # 相对采集起点（传感器时间轴）

        if ($useTime) {
            # 最近样本行 + 落在 ±WindowSec 内的行（按时间，不按序号）
            $center = 0
            $best = [double]::MaxValue
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $d = [math]::Abs([double]$elapsed[$i] - $atElapsed)
                if ($d -lt $best) { $best = $d; $center = $i }
            }
            $lo = $center; $hi = $center
            for ($i = $center; $i -ge 0; $i--) {
                if ([math]::Abs([double]$elapsed[$i] - $atElapsed) -le $WindowSec) { $lo = $i } else { break }
            }
            for ($i = $center; $i -lt $rows.Count; $i++) {
                if ([math]::Abs([double]$elapsed[$i] - $atElapsed) -le $WindowSec) { $hi = $i } else { break }
            }
        } else {
            # 比例模式：位置要加上预热段再算比例（否则整体前移 WarmupSec 秒）
            $spanMs = ($WarmupSec * 1000.0) + $totalMs
            $pctFull = 100.0 * (($WarmupSec * 1000.0) + $atMs) / $spanMs
            $center = [int][math]::Round(($pctFull / 100.0) * ($rows.Count - 1))
            if ($center -lt 0) { $center = 0 }
            if ($center -gt ($rows.Count - 1)) { $center = $rows.Count - 1 }
            $lo = [math]::Max(0, $center - $half)
            $hi = [math]::Min($rows.Count - 1, $center + $half)
        }

        # 窗口内逐字段求平均与峰值；「当时」取中心样本
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
            start_frame  = $startFrame
            frames       = [int]$s.frames
            ms           = [double]$s.ms
            at_pct       = [math]::Round($atPct, 1)
            at_elapsed_s = [math]::Round($atElapsed, 1)
            samples      = ($hi - $lo + 1)
            at           = $at
            avg          = $avg
            peak         = $peak
        })
    }

    $out.items = @($items)
    if ($items.Count -eq 0) { $out.reason = 'noStutter' }
    return $out
}
