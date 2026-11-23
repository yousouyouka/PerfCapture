# 后台进程干扰聚合探针（2.1.17 / F4-2）
#
# 只验证 bgproc.ps1 的聚合：同名多实例合并、按全部采样时刻摊平均、Top 3 截断、
# 坏数据跳过，不跑采集。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-bgproc.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$mod = Join-Path $root 'src\app\bgproc.ps1'

$script:fail = 0
$script:pass = 0
function Assert($cond, $name, $detail) {
    if ($cond) { $script:pass++; Write-Host ('  OK   ' + $name) -ForegroundColor DarkGray }
    else { $script:fail++; Write-Host ('  FAIL ' + $name + '  ' + $detail) -ForegroundColor Red }
}

if (-not (Test-Path -LiteralPath $mod)) { Write-Host '缺少 bgproc.ps1' -ForegroundColor Red; exit 1 }
. $mod
if (-not (Get-Command Get-BackgroundTop -ErrorAction SilentlyContinue)) {
    Write-Host 'bgproc.ps1 未导出 Get-BackgroundTop' -ForegroundColor Red; exit 1
}
function Row($t, $n, $p, $v) { [pscustomobject]@{ elapsed_s = $t; name = $n; pid = $p; cpu_pct = $v } }

Write-Host '== 1. 同名多实例合并 ==' -ForegroundColor Cyan
$rows = @(
    (Row 5 'chrome' 100 12.0), (Row 5 'chrome' 101 8.0), (Row 5 'explorer' 200 3.0),
    (Row 10 'chrome' 100 20.0), (Row 10 'chrome' 101 4.0), (Row 10 'explorer' 200 5.0)
)
$r = Get-BackgroundTop -Rows $rows -IntervalSec 5
Assert ($r.state -eq 'ok') '有样本 → ok' ('实际 ' + $r.state)
Assert ($r.sample_count -eq 2) '2 个采样时刻' ('实际 ' + $r.sample_count)
Assert (@($r.procs).Count -eq 2) '合并后 2 个进程名' ('实际 ' + @($r.procs).Count)
$ch = @($r.procs | Where-Object { $_.name -eq 'chrome' })[0]
Assert ($ch.avg_cpu_pct -eq 22.0) 'chrome 平均 (20+24)/2 = 22' ('实际 ' + $ch.avg_cpu_pct)
Assert ($ch.peak_cpu_pct -eq 24.0) 'chrome 峰值 20+4=24' ('实际 ' + $ch.peak_cpu_pct)
Assert ($ch.samples -eq 2) 'chrome 出现在 2 个采样时刻（不是 4 行）' ('实际 ' + $ch.samples)

Write-Host '== 2. 按全部采样时刻摊平均（不按出现次数虚高）==' -ForegroundColor Cyan
$rows2 = @(
    (Row 5 'shortlived' 300 90.0),
    (Row 5 'steady' 400 10.0), (Row 10 'steady' 400 10.0), (Row 15 'steady' 400 10.0)
)
$r2 = Get-BackgroundTop -Rows $rows2
$sh = @($r2.procs | Where-Object { $_.name -eq 'shortlived' })[0]
$st = @($r2.procs | Where-Object { $_.name -eq 'steady' })[0]
Assert ($sh.avg_cpu_pct -eq 30.0) '只出现 1 次的 90% 摊成 30%（3 个时刻）' ('实际 ' + $sh.avg_cpu_pct)
Assert ($sh.samples -eq 1) '同时如实给出现次数 1' ('实际 ' + $sh.samples)
Assert ($st.avg_cpu_pct -eq 10.0) '全程 10% 仍是 10' ('实际 ' + $st.avg_cpu_pct)
Assert (@($r2.procs)[0].name -eq 'shortlived') '按全程平均排序，短暂高占用在前' ('实际 ' + @($r2.procs)[0].name)

Write-Host '== 3. Top 3 截断与排序 ==' -ForegroundColor Cyan
$rows3 = @()
for ($i = 1; $i -le 6; $i++) {
    $rows3 += Row 5 ('p' + $i) (100 + $i) ($i * 3.0)
    $rows3 += Row 10 ('p' + $i) (100 + $i) ($i * 3.0)
}
$r3 = Get-BackgroundTop -Rows $rows3
Assert (@($r3.procs).Count -eq 3) '只返回 Top 3' ('实际 ' + @($r3.procs).Count)
Assert (@($r3.procs)[0].name -eq 'p6') '最高占用排第一' ('实际 ' + @($r3.procs)[0].name)
Assert (@($r3.procs)[2].name -eq 'p4') '第三名是 p4' ('实际 ' + @($r3.procs)[2].name)

Write-Host '== 4. 坏数据不冒充数值 ==' -ForegroundColor Cyan
$r4 = Get-BackgroundTop -Rows @( (Row 5 'bad' 1 'NA'), (Row 5 '' 2 10), (Row 5 'ok' 3 'oops') )
Assert ($r4.state -eq 'noSamples') '全坏数据 → noSamples，不写空数组冒充正常' ('实际 ' + $r4.state)
$r5 = Get-BackgroundTop -Rows @()
Assert ($r5.state -eq 'noSamples') '无行 → noSamples' ('实际 ' + $r5.state)
Assert ($r5.sample_count -eq 0) '采样时刻数为 0' ('实际 ' + $r5.sample_count)

Write-Host ''
Write-Host ("结果: " + $script:pass + " 通过 / " + $script:fail + " 失败") -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
exit 0
