# 后台进程干扰聚合（2.1.17 / F4-2；纯函数 · 无副作用）
#
# 输入是采样器写出的独立 CSV 行（elapsed_s / name / pid / cpu_pct），本模块只做聚合：
#   - 同一采样时刻里，同名进程的多个实例加起来（chrome 开 20 个进程不该各占一行）；
#   - 平均值以「全部采样时刻数」为分母，进程只出现几秒就按几秒摊，不按出现次数虚高；
#   - 同时给 active_samples，让报告能说清「只在 x / y 次采样中出现」。
#
# 只读进程 CPU 时间，不碰其它进程的 GPU（没有可靠的零驱动通道）。
# 与《后续功能规划与优先级.md》§3.5（F4-2）对应。

$script:BgProcTop = 3

function ConvertTo-BgNum($v) {
    if ($null -eq $v) { return $null }
    $s = ([string]$v).Trim()
    if (-not $s -or $s -eq 'NA') { return $null }
    $d = 0.0
    if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

# 返回 ordered hashtable：
#   state          ok / noSamples
#   sample_count   采样时刻数（不是进程行数）
#   interval_sec   采样间隔（由引擎传入，写进报告口径）
#   procs[]        { name, avg_cpu_pct, peak_cpu_pct, samples }，按 avg 降序，最多 Top N
function Get-BackgroundTop {
    param(
        $Rows,
        [int]$Top = $script:BgProcTop,
        [int]$IntervalSec = 5
    )

    $out = [ordered]@{
        state        = 'noSamples'
        sample_count = 0
        interval_sec = $IntervalSec
        procs        = @()
    }
    $rows = @($Rows)
    if ($rows.Count -eq 0) { return $out }

    # 时刻 → 进程名 → 该时刻合计 CPU%
    $byTime = @{}
    $times = @{}
    foreach ($r in $rows) {
        if ($null -eq $r) { continue }
        $t = [string]$r.elapsed_s
        $nm = [string]$r.name
        $v = ConvertTo-BgNum $r.cpu_pct
        if (-not $t -or -not $nm -or $null -eq $v) { continue }
        $times[$t] = $true
        if (-not $byTime.ContainsKey($t)) { $byTime[$t] = @{} }
        if ($byTime[$t].ContainsKey($nm)) { $byTime[$t][$nm] += $v }
        else { $byTime[$t][$nm] = $v }
    }
    $ticks = @($times.Keys)
    if ($ticks.Count -eq 0) { return $out }

    # 进程名 → 各时刻占用
    $byName = @{}
    foreach ($t in $ticks) {
        foreach ($nm in $byTime[$t].Keys) {
            if (-not $byName.ContainsKey($nm)) { $byName[$nm] = @() }
            $byName[$nm] += $byTime[$t][$nm]
        }
    }

    $list = New-Object System.Collections.ArrayList
    foreach ($nm in $byName.Keys) {
        $vals = @($byName[$nm])
        $sum = 0.0
        $peak = 0.0
        foreach ($v in $vals) {
            $sum += [double]$v
            if ([double]$v -gt $peak) { $peak = [double]$v }
        }
        [void]$list.Add([ordered]@{
            name          = $nm
            avg_cpu_pct   = [math]::Round($sum / [double]($ticks.Count), 1)
            peak_cpu_pct  = [math]::Round($peak, 1)
            samples       = $vals.Count
        })
    }
    # 注意：OrderedDictionary 的 key 不是 .NET 属性，Sort-Object -Property 'avg_cpu_pct'
    # 会取到 $null 从而退化成哈希表遍历顺序（Top 3 看着像随机）。必须显式索引取值。
    $sorted = @($list | Sort-Object -Property { [double]$_['avg_cpu_pct'] } -Descending | Select-Object -First $Top)
    $out.state = 'ok'
    $out.sample_count = $ticks.Count
    $out.procs = @($sorted)
    return $out
}
