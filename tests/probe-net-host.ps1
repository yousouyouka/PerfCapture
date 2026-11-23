# 网络宿主链路无头自检（2.2.1）：不启动 GUI，用桩驱动 采样→累计→落盘→汇总→推送 全链路。
# 样本以 JSON 字符串入队（与真实采样 runspace 的入队方式一致——跨 runspace 嵌套集合
# 直接入队会在宿主枚举时抛 Argument types do not match，2.2.1 修复过的根因）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-net-host.ps1
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$out = New-Object System.Collections.Generic.List[string]
function Ok($m) { $out.Add('  PASS ' + $m); $script:np++ }
function Bad($m) { $out.Add('  FAIL ' + $m); $script:nf++ }

$script:np = 0; $script:nf = 0
$work = Join-Path $env:TEMP ('PerfCap-net-host-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $work -Force | Out-Null

# ---- 桩：宿主环境（不加载 00-90 全链，只给 36 需要的全局） ----
$script:DataDir = $work
$script:Root = $root
function Write-AppLog([string]$m, [string]$lvl = 'INFO') { $out.Add('  [log:' + $lvl + '] ' + $m) }
$script:UiPushed = New-Object System.Collections.ArrayList
function Send-ToUi($payload) { [void]$script:UiPushed.Add($payload) }
$script:Cfg = @{ netAlertDayMB = 0; netAlertMonthMB = 0 }

# ---- dot-source 被测模块 ----
. (Join-Path $root 'src\app\36-NetMetrics.ps1')
Ok '36-NetMetrics.ps1 dot-source 成功'

# ---- 1. 持久化初始化（空历史） ----
Initialize-NetPersistence
if ($script:NetDaysPath -and ($script:NetDaysPath -like ($work + '*'))) { Ok ('days.json 路径在 DataDir 下: ' + $script:NetDaysPath) } else { Bad ('days.json 路径异常: ' + $script:NetDaysPath) }

# ---- 2. persist 消费者 ----
Set-NetConsumer 'persist' $true
if ($script:NetConsumers.ContainsKey('persist')) { Ok 'persist 消费者已登记' } else { Bad 'persist 消费者未登记' }
if ($script:NetQueue) { Ok '采样队列已创建' } else { Bad '采样队列未创建' }

# ---- 3. 以真实方式入队（JSON 字符串）两帧样本 → Invoke-NetTick ----
function Enqueue-JsonSample([string]$At, [object[]]$Ifs, [object[]]$Conns) {
    $payload = [ordered]@{ at = $At; ifs = @($Ifs); conns = @($Conns); connTruncated = $false }
    [void]$script:NetQueue.Enqueue(($payload | ConvertTo-Json -Depth 6 -Compress))
}
$if1 = [ordered]@{ ifIndex = 5; name = 'WLAN'; desc = 'Intel'; kind = 'wifi'; status = 'Up'; linkSpeed = ''; recvBps = 1000; sentBps = 100; recvTotal = 1000000; sentTotal = 100000 }
$if2 = [ordered]@{ ifIndex = 12; name = 'VPN'; desc = 'Radmin'; kind = 'virtual'; status = 'Up'; linkSpeed = ''; recvBps = 500; sentBps = 50; recvTotal = 2000; sentTotal = 200 }
Enqueue-JsonSample 't1' @($if1, $if2) @()
Invoke-NetTick
if ($script:NetUiRates) { Ok ('UiRates 快照: recv=' + $script:NetUiRates.recv) } else { Bad 'UiRates 快照为空（浮窗/托盘会永远 N/A）' }
if ($script:NetLastTotals.ContainsKey(5)) { Ok '首帧建立基线（LastTotals）' } else { Bad '首帧没建立基线' }

# ---- 4. 第二帧：增量差分 ----
$if1b = [ordered]@{ ifIndex = 5; name = 'WLAN'; desc = 'Intel'; kind = 'wifi'; status = 'Up'; linkSpeed = ''; recvBps = 2000; sentBps = 200; recvTotal = 2000000; sentTotal = 200000 }
$if2b = [ordered]@{ ifIndex = 12; name = 'VPN'; desc = 'Radmin'; kind = 'virtual'; status = 'Up'; linkSpeed = ''; recvBps = 600; sentBps = 60; recvTotal = 3000; sentTotal = 300 }
Enqueue-JsonSample 't2' @($if1b, $if2b) @()
Invoke-NetTick
# 注：累计增量会在同一 tick 内触发首次落盘并被清空（持久化设计如此），
# 数值是否正确以下面 days.json 与汇总快照为准，这里只断言「落盘已发生」。
if (Test-Path -LiteralPath $script:NetDaysPath) { Ok 'tick 后落盘已发生' } else { Bad 'tick 后没有落盘' }

# ---- 5. 落盘 → days.json 内容（首帧累计会立刻触发首次落盘，数据应已落盘） ----
Flush-NetStats
if (Test-Path -LiteralPath $script:NetDaysPath) { Ok 'days.json 已落盘' } else { Bad 'days.json 没有落盘' }
$doc = $null
try { $doc = Get-Content -LiteralPath $script:NetDaysPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
if ($doc -and $doc.PSObject.Properties['__meta']) { Ok 'days.json 带 __meta（适配器种类）' } else { Bad 'days.json 缺 __meta（历史聚合无法区分物理/虚拟）' }
$dayKey = (Get-Date).ToString('yyyy-MM-dd')
$dayNode = if ($doc) { $doc.PSObject.Properties[$dayKey] } else { $null }
$dayRecv = if ($dayNode -and $dayNode.Value.'5') { [double]$dayNode.Value.'5'.r } else { 0 }
if ($dayRecv -ge 1000000) { Ok "按日累计落盘数值正确（WLAN recv=$dayRecv ≥ 1,000,000）" } else { Bad "按日累计数值不对: WLAN recv=$dayRecv" }

# ---- 6. 汇总快照：今日/本月/天数/月数 ----
$totals = Get-NetTotalsSnapshot
$sumT = [double]$totals.today.recv + [double]$totals.today.sent
$sumM = [double]$totals.month.recv + [double]$totals.month.sent
if ($sumT -gt 0) { Ok ('今日汇总有值: ' + $sumT) } else { Bad '今日汇总为 0（Get-NetDaySum 没算进增量）' }
if ($sumM -ge $sumT) { Ok ('本月汇总 ≥ 今日: ' + $sumM) } else { Bad '本月汇总比今日还小' }
if ($totals.days.Count -eq 30) { Ok '近 30 天序列完整' } else { Bad ('近 30 天序列异常: ' + $totals.days.Count) }
if ($totals.months.Count -eq 12) { Ok '近 12 个月序列完整' } else { Bad ('近 12 个月序列异常: ' + $totals.months.Count) }
# 序列化自证：Send-ToUi 走 ConvertTo-Json，嵌套 List[object] 必须能原样出 JSON。
# 注意 @($totals.days) 对 List[object] 会抛 Argument types do not match（断言会被静默跳过），
# 取数量用 .Count，不要用 @() 包一层。
$totalsJson = @{ type = 'netTotals'; totals = $totals } | ConvertTo-Json -Depth 6 -Compress
$dayJsonCount = ([regex]::Matches($totalsJson, '"d":')).Count
if ($totalsJson -match '"today"' -and $dayJsonCount -eq 30) { Ok "netTotals 可序列化为 JSON（30 天齐全，长度 $($totalsJson.Length)）" } else { Bad "netTotals JSON 序列化异常（Send-ToUi 会静默丢包）：days=$dayJsonCount" }

# ---- 7. netTotals / netCaps 推送时机：打开页面应立即收到一次 ----
Set-NetConsumer 'page' $true
$gotTotals = @($script:UiPushed | Where-Object { $_.type -eq 'netTotals' }).Count
if ($gotTotals -ge 1) { Ok '打开网络页立即收到 netTotals' } else { Bad '打开网络页没有收到 netTotals（今日/本月初次显示会一直是空）' }
$gotCaps = @($script:UiPushed | Where-Object { $_.type -eq 'netCaps' }).Count
if ($gotCaps -ge 1) { Ok '打开网络页收到 netCaps（状态徽标）' } else { Bad '打开网络页没收到 netCaps' }

# ---- 8. 页面打开后 netSample 应推给 UI（真实 JSON 路径） ----
$script:UiPushed.Clear() | Out-Null
$if1c = [ordered]@{ ifIndex = 5; name = 'WLAN'; desc = 'Intel'; kind = 'wifi'; status = 'Up'; linkSpeed = ''; recvBps = 3000; sentBps = 300; recvTotal = 2500000; sentTotal = 250000 }
Enqueue-JsonSample 't3' @($if1c) @()
Invoke-NetTick
$uiNetSample = @($script:UiPushed | Where-Object { $_.type -eq 'netSample' })
if ($uiNetSample.Count -ge 1) { Ok 'netSample 已推给 UI（页面打开状态）' } else { Bad 'netSample 未推给 UI（页面打开也看不到数字）' }
$p0 = if ($uiNetSample.Count) { $uiNetSample[0] } else { $null }
if ($p0 -and $p0.sample -and @($p0.sample.ifs).Count -ge 1 -and $p0.sample.ifs[0].recvBps -eq 3000) { Ok '推送样本的 ifs 字段完整（速率可渲染）' } else { Bad '推送样本 ifs 字段缺失或速率丢失' }

# ---- 9. 真实采样器（runspace）端到端：JSON 入队 → 宿主解析 ----
# 说明：无头环境没有 WinForms 程序集，计时器起不来（真实应用里存在）——
# 这里直接驱动 Invoke-NetTick 验证 runspace → JSON → 宿主解析全链。
$script:UiPushed.Clear() | Out-Null
$script:NetDayAcc = @{}
$script:NetLastTotals = @{}
Stop-NetSampler
Set-NetConsumer 'persist' $true   # 重建 worker（真实应用里计时器也一并启动）
Start-Sleep -Seconds 4
$raw1 = $null
if ($script:NetQueue.TryDequeue([ref]$raw1)) {
    $out.Add('  [raw] type=' + $raw1.GetType().Name + ' len=' + ([string]$raw1).Length + ' head=' + (([string]$raw1).Substring(0, [Math]::Min(300, ([string]$raw1).Length))))
}
Invoke-NetTick
$gotReal = @($script:UiPushed | Where-Object { $_.type -eq 'netSample' }).Count
if ($gotReal -ge 1) { Ok ("真实 runspace 产出 $gotReal 个 netSample（JSON 入队 → 宿主解析 → 推送全链通）") } else { Bad '真实 runspace 4 秒内没有产出任何 netSample（采样器线程或队列有问题！）' }
$allReal = @($script:UiPushed | Where-Object { $_.type -eq 'netSample' })
$anyIfs = $allReal | Where-Object { $_.sample -and @($_.sample.ifs).Count -ge 1 }
if ($anyIfs) { Ok '真实样本带网卡列表（首帧 CIM 预热可能为空，后续帧有数）' } else {
    Bad '真实样本 ifs 全部为空（Get-NetAdapterStatistics 在采样 runspace 里失败？）'
    $dump = @($allReal | Select-Object -First 1)
    if ($dump.Count) { $out.Add('  [dump] ' + ($dump[0].sample | ConvertTo-Json -Depth 4 -Compress)) }
    $out.Add('  [dump] pushed=' + $allReal.Count)
}

# ---- 清理 ----
Stop-NetSampler
try { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }

$out.Add('')
if ($script:nf -eq 0) { $out.Add("== 全部通过（$script:np 项）==") } else { $out.Add("== 失败 $script:nf 项 / 通过 $script:np 项 ==") }
[IO.File]::WriteAllLines((Join-Path $root 'tests\probe-net-host.log'), $out, (New-Object Text.UTF8Encoding($true)))
Write-Host ('完成：tests\probe-net-host.log（失败 ' + $script:nf + '）')
if ($script:nf -gt 0) { exit 1 } else { exit 0 }
