# 网络页真 WebView2 探针（2.1.18）：offscreen Form 加载真实 ui/index.html，
# 点击侧边栏「网络」→ 注入两帧构造样本 → 回读 DOM 与计算样式。
# 断言：侧边栏入口存在、页面切换生效、卡片/曲线/合计真实渲染、
#       曲线颜色来自 tokens 变量（亮/暗两主题都可解析出具体色值）。
# CDP/脚本等待一律泵消息（DoEvents + Sleep），不用 .Result 阻塞。
# 用法：powershell -STA -NoProfile -ExecutionPolicy Bypass -File tests\probe-network-webview2.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host '== 网络页真 WebView2 自证 ==' -ForegroundColor Cyan

$work = Join-Path $env:TEMP ('PerfCapture-NET-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $work -Force)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try {
    Add-Type -Path (Join-Path $root 'lib\Microsoft.Web.WebView2.Core.dll') -ErrorAction Stop
    Add-Type -Path (Join-Path $root 'lib\Microsoft.Web.WebView2.WinForms.dll') -ErrorAction Stop
} catch { Bad ('WebView2 程序集加载失败: ' + $_.Exception.Message); exit 1 }

$form = New-Object System.Windows.Forms.Form
$form.ShowInTaskbar = $false
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(-3000, -3000)
$form.Size = New-Object System.Drawing.Size(1240, 800)
$wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
$wv.Dock = [System.Windows.Forms.DockStyle]::Fill
$form.Controls.Add($wv)
$env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $work 'profile'

# 宿主收到的 UI 消息计数（进页面应自动发 netStart）
$script:UiMsgs = New-Object System.Collections.ArrayList
$wv.add_WebMessageReceived({
    param($s, $e)
    try { [void]$script:UiMsgs.Add([string]$e.WebMessageAsJson) } catch { }
})

function Await-Task($task, [int]$TimeoutMs) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $task.IsCompleted -and $sw.ElapsedMilliseconds -lt $TimeoutMs) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 25
    }
    return $task.IsCompleted
}
function Pump([int]$Ms) { for ($i = 0; $i -lt [Math]::Max(1, [int]($Ms / 25)); $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 25 } }
function Exec([string]$Js, [int]$TimeoutMs = 8000) {
    $q = $wv.ExecuteScriptAsync($Js)
    if (-not (Await-Task $q $TimeoutMs)) { throw '脚本执行超时' }
    $raw = [string]$q.GetAwaiter().GetResult()
    $inner = $raw
    try { $tmp = $raw | ConvertFrom-Json; if ($tmp -is [string]) { $inner = $tmp } } catch { }
    return ($inner | ConvertFrom-Json)
}

try {
    $form.Show()
    $t = $wv.EnsureCoreWebView2Async($null)
    if (-not (Await-Task $t 30000)) { Bad 'WebView2 初始化超时'; $form.Dispose(); exit 1 }
    [void]$t.GetAwaiter().GetResult()
    Ok 'WebView2 offscreen 初始化成功'
    $idxPath = Join-Path $root 'ui\index.html'
    $null = $wv.CoreWebView2.Navigate(([Uri]$idxPath).AbsoluteUri)
    Pump 2500
    Ok '真实 ui/index.html 已加载（file://）'
} catch { Bad ('初始化失败: ' + $_.Exception.Message); $form.Dispose(); exit 1 }

# ---- 1. 侧边栏入口与页面切换 ----
$r1 = Exec "(function(){ var b=document.querySelector('button.nav-item[data-page=""network""]'); var p=document.querySelector('.page[data-page=""network""]'); return JSON.stringify({ nav: !!b, i18n: b ? b.textContent.trim() : '', pageHidden: p ? p.hidden : null, cssLoaded: !!Array.prototype.find.call(document.styleSheets, function(s){ try { return (s.href||'').indexOf('network.css') >= 0; } catch(e){ return false; } }) }); })()"
Assert ($r1.nav -eq $true) '侧边栏「网络」入口存在'
Assert ($r1.pageHidden -eq $true) '初始状态网络页隐藏'
Assert ($r1.cssLoaded -eq $true) 'network.css 已加载'

$null = Exec "document.querySelector('button.nav-item[data-page=""network""]').click(); true"
Pump 400
$r2 = Exec "(function(){ var p=document.querySelector('.page[data-page=""network""]'); return JSON.stringify({ visible: p && !p.hidden }); })()"
Assert ($r2.visible -eq $true) '点击后网络页显示'

$netStartSent = ($script:UiMsgs | Where-Object { $_ -match 'netStart' }).Count -gt 0
Assert $netStartSent '进页面已自动发送 netStart 命令'

# ---- 2. 注入两帧样本并回读渲染 ----
$inject = @'
(function(){
  function mk(ifIndex, name, kind, recvBps, sentBps, recvTotal, sentTotal, link){
    return { ifIndex: ifIndex, name: name, desc: name, kind: kind, status: 'Up',
             linkSpeed: link || '', recvBps: recvBps, sentBps: sentBps,
             recvTotal: recvTotal, sentTotal: sentTotal };
  }
  window.PerfNetwork.handle({ type: 'netSample', caps: { running: true }, sample: { at: 't1', ifs: [
      mk(5, 'WLAN', 'wifi', 1546, 300, 1048576, 204800, '866.7 Mbps'),
      mk(20, 'Ethernet', 'ethernet', 1024, 100, 524288, 51200, '1 Gbps'),
      mk(12, 'VPN', 'virtual', 800, 40, 4096, 4096, '100 Mbps')
  ] } });
  window.PerfNetwork.handle({ type: 'netSample', caps: { running: true }, sample: { at: 't2', ifs: [
      mk(5, 'WLAN', 'wifi', 1546000, 300, 1048576, 204800, '866.7 Mbps'),
      mk(20, 'Ethernet', 'ethernet', 1024, 100, 524288, 51200, '1 Gbps'),
      mk(12, 'VPN', 'virtual', 800, 40, 4096, 4096, '100 Mbps')
  ] } });
  return true;
})()
'@
$null = Exec $inject
Pump 300

# 注入持久化汇总（宿主 netTotals 的形状）
$null = Exec @'
(function(){
  function mk(d, recv, sent){ return { d: d, recv: recv, sent: sent }; }
  var days = [], months = [];
  for (var i = 29; i >= 0; i--) days.push(mk('2026-11-' + (23 - i < 10 ? '0' + (23 - i) : (23 - i)), i === 0 ? 204800 : 51200, 5120));
  for (var j = 11; j >= 0; j--) months.push(mk('2026-' + (12 - j < 10 ? '0' + (12 - j) : (12 - j)), 31457280, 3145728));
  /* 走真实 bridge 分发（不是直接调 PerfNetwork.handle）：2.2.1 的根因就是 bridge 漏转发 netTotals */
  handleMessage({ type: 'netTotals', totals: {
    today: { recv: 102400, sent: 10240 }, month: { recv: 3145728, sent: 524288 },
    days: days, months: months, meta: {} } });
  return true;
})()
'@
Pump 200

$r3 = Exec @"
(function(){
  function cs(el,p){ return el ? getComputedStyle(el).getPropertyValue(p).trim() : ''; }
  var cards = document.querySelectorAll('.nt-card');
  var recvLine = document.querySelector('.nt-line-recv');
  var sentLine = document.querySelector('.nt-line-sent');
  var first = cards[0];
  return JSON.stringify({
    cards: cards.length,
    firstName: first ? first.querySelector('.nt-name').textContent : '',
    chipKind: first ? first.querySelector('.nt-chip').dataset.kind : '',
    recvText: first ? first.querySelector('.nt-rate-recv .nt-v').textContent : '',
    totalsText: first ? first.querySelector('.nt-totals').textContent : '',
    recvPathD: recvLine ? recvLine.getAttribute('d') : '',
    sentPathD: sentLine ? sentLine.getAttribute('d') : '',
    recvStroke: cs(recvLine, 'stroke'),
    totalRecv: document.getElementById('netTotalRecv').textContent,
    totalSent: document.getElementById('netTotalSent').textContent,
    stateAttr: document.getElementById('netState').dataset.state,
    chipFont: cs(document.querySelector('.nt-chip'), 'font-size')
  });
})()
"@
Assert ($r3.cards -eq 3) '三块网卡渲染出三张卡（实际 ' + $r3.cards + '）'
Assert ($r3.firstName -eq 'WLAN') '排序后首卡是吞吐最大的 WLAN'
Assert ($r3.chipKind -eq 'wifi') 'WLAN 徽标标记为 Wi-Fi'
Assert ($r3.recvText -eq '1.5 MB/s') '下行速率格式化正确（1546000 → 1.5 MB/s，实际 ' + $r3.recvText + '）'
Assert ($r3.recvPathD -and $r3.recvPathD.Length -gt 10) '下行曲线 path 已真实绘制'
Assert ($r3.sentPathD -and $r3.sentPathD.Length -gt 10) '上行曲线 path 已真实绘制'
Assert ($r3.recvStroke -match '^\s*(rgb|rgba|hsl|#)') "曲线颜色来自 tokens（实际 $($r3.recvStroke)）"
Assert ($r3.totalRecv -ne '—' -and $r3.totalRecv.Length -gt 0) '顶部下行合计有值（实际 ' + $r3.totalRecv + '）'
Assert ($r3.stateAttr -eq 'on') '状态徽标为采样中'
Assert ($r3.chipFont -ne '' -and [double]($r3.chipFont -replace '[a-z]', '') -gt 0 -and [double]($r3.chipFont -replace '[a-z]', '') -lt 12) '徽标字号落在小字规范内（实际 ' + $r3.chipFont + '）'
Assert ($r3.totalsText -match '1048576|1\.0 MB') '每卡累计行含计数器总量（实际 ' + $r3.totalsText + '）'

# ---- 3. 暗色主题同样成立 ----
$null = Exec "document.documentElement.setAttribute('data-theme','dark'); true"
Pump 200
$r4 = Exec "(function(){ var el=document.querySelector('.nt-line-recv'); var card=document.querySelector('.nt-card'); return JSON.stringify({ stroke: getComputedStyle(el).getPropertyValue('stroke').trim(), cardBg: getComputedStyle(card).getPropertyValue('background-color') }); })()"
Assert ($r4.stroke -match '^\s*(rgb|rgba|hsl|#)') '暗色主题下曲线颜色仍可解析'

# ---- 4. 持久化汇总渲染 ----
$r5 = Exec "(function(){ return JSON.stringify({ today: document.getElementById('netToday').textContent, month: document.getElementById('netMonth').textContent, dayBars: document.getElementById('netBarsDays').children.length, monthBars: document.getElementById('netBarsMonths').children.length, histHidden: document.getElementById('netHistEmpty').hidden, barR: getComputedStyle(document.querySelector('.nt-bar-r')).backgroundColor }); })()"
Assert ($r5.today -eq '110.0 KB') '今日合计 = 110.0 KB（实际 ' + $r5.today + '）'
Assert ($r5.month -eq '3.5 MB') '本月合计 = 3.5 MB（实际 ' + $r5.month + '）'
Assert ($r5.dayBars -eq 30) '近 30 天渲染 30 根柱（实际 ' + $r5.dayBars + '）'
Assert ($r5.monthBars -eq 12) '近 12 个月渲染 12 根柱'
Assert ($r5.histHidden -eq $true) '有数据时历史空状态隐藏'
Assert ($r5.barR -match 'rgb') "柱状收段颜色来自 tokens（实际 $($r5.barR)）"

# ---- 5. 第二轮验收三条：热键搬家 / 告警卡位置与排版（2.2.1） ----
$r6 = Exec @"
(function(){
  var setPage = document.querySelector('.page[data-page="settings"]');
  var capPage = document.querySelector('.page[data-page="capture"]');
  var netPage = document.querySelector('.page[data-page="network"]');
  var hk = document.getElementById('chkHotkeys');
  var startBtn = document.getElementById('hkStartBtn');
  var stopBtn = document.getElementById('hkStopBtn');
  var oldInputs = document.getElementById('hkStartKey') || document.getElementById('hkStartCtrl') || document.getElementById('hkStopKey');
  var alertCard = netPage ? netPage.querySelector('.net-alertcard') : null;
  var dayInput = document.getElementById('netAlertDay');
  var dayLabel = dayInput && dayInput.closest('.nt-field') ? dayInput.closest('.nt-field').querySelector('span') : null;
  function rect(e){ if(!e) return null; var r=e.getBoundingClientRect(); return { l:r.left, r:r.right, t:r.top, b:r.bottom, w:r.width, h:r.height }; }
  return JSON.stringify({
    hkInCapture: !!(capPage && capPage.contains(hk)),
    hkInSettings: !!(setPage && setPage.contains(hk)),
    oldLabels: !!document.getElementById('hkStartLabel') || !!document.getElementById('hkFailRow'),
    startLabel: startBtn ? startBtn.textContent.trim() : '',
    hasStopBtn: !!stopBtn,
    oldInputs: !!oldInputs,
    alertInNet: !!alertCard,
    alertInSettings: !!(setPage && setPage.querySelector('#netAlertDay')),
    labelR: rect(dayLabel), inputR: rect(dayInput),
    hintText: (function(){ var e=document.querySelector('[data-i18n="settings.hotkeySetHint"]'); return e ? e.textContent : ''; })(),
    alertHintText: (function(){ var e=document.querySelector('.net-alertcard [data-i18n="net.alertHint"]'); return e ? e.textContent : ''; })()
  });
})()
"@
Assert ($r6.hkInCapture -eq $true) '热键开关已在「采集设置」页内'
Assert ($r6.hkInSettings -eq $false) '设置页不再有热键开关'
Assert ($r6.oldLabels -eq $false) '设置页旧快捷键卡（hkStartLabel/hkFailRow）已删除'
Assert ($r6.hasStopBtn -eq $true) '停止热键捕获按钮存在（hkStopBtn）'
Assert ($r6.oldInputs -eq $false) '旧的下拉/修饰键勾选（hkStartKey/hkStartCtrl/hkStopKey）已删除'
Assert ($r6.startLabel -match 'Ctrl\+Alt\+F9') "开始按钮显示当前热键（实际 '$($r6.startLabel)'）"
Assert ($r6.alertInNet -eq $true) '流量告警卡已在网络页内'
Assert ($r6.alertInSettings -eq $false) '设置页不再有流量告警'
Assert ($r6.labelR.w -gt 0 -and $r6.inputR.w -gt 0) '阈值标签与输入框都有实际尺寸'
Assert ($r6.inputR.l -ge ($r6.labelR.r - 1)) "阈值标签不遮挡输入框（label 右 $($r6.labelR.r) ≤ input 左 $($r6.inputR.l)）"
Assert ($r6.hintText -ne '' -and $r6.hintText -notmatch 'settings\.hotkeySetHint') '热键说明文案已渲染（不是 key 原文）'
Assert ($r6.alertHintText -ne '' -and $r6.alertHintText -notmatch 'net\.alertHint') '告警说明文案已渲染（不是 key 原文）'

# ---- 6. 今日必须在本月左侧且同排（2.2.2） ----
$r7 = Exec "(function(){ var t=document.getElementById('netToday').getBoundingClientRect(); var m=document.getElementById('netMonth').getBoundingClientRect(); return JSON.stringify({ tl: t.left, tt: t.top, ml: m.left, mt: m.top }); })()"
Assert ([double]$r7.tl -lt [double]$r7.ml) "今日在本月左侧（今日左 $($r7.tl) / 本月左 $($r7.ml)）"
Assert ([math]::Abs([double]$r7.tt - [double]$r7.mt) -lt 1) "今日与本月同一排（top $($r7.tt) / $($r7.mt)）"

# ---- 7. 批次 A（2.2.6）：连接视图过滤与搜索 + 四层口径表 ----
$null = Exec @'
(function(){
  PerfNetwork.handle({ type: 'netSample', caps: { running: true }, sample: { at: 'f1', ifs: [], conns: [
    { p: 10, n: 'alpha', pr: 'TCP', la: '192.168.1.5', lp: 5000, ra: '203.0.113.9', rp: 443, st: 'ESTABLISHED', sv: 'HTTPS', hn: 'cdn.example.com' },
    { p: 20, n: 'beta', pr: 'UDP', la: '0.0.0.0', lp: 5353, ra: '*', rp: 0, st: '', sv: 'mDNS', hn: '' }
  ] } });
  return true;
})()
'@
Pump 200
$r8 = Exec @"
(function(){
  PerfNetwork.applyConnFilters('alpha','','');
  var q1 = document.querySelectorAll('#netConnBody tr').length;
  PerfNetwork.applyConnFilters('','UDP','');
  var q2 = document.querySelectorAll('#netConnBody tr').length;
  PerfNetwork.applyConnFilters('','','mDNS');
  var q3 = document.querySelectorAll('#netConnBody tr').length;
  PerfNetwork.applyConnFilters('zzz','','');
  var q4 = document.querySelectorAll('#netConnBody tr').length;
  var noMatch = document.getElementById('netConnNoMatch').hidden;
  var hint = document.getElementById('netConnHint').textContent;
  PerfNetwork.applyConnFilters('','','');
  var q5 = document.querySelectorAll('#netConnBody tr').length;
  var d = document.getElementById('netCaliber');
  d.open = true;
  var rows = d.querySelectorAll('tbody tr').length;
  var badges = d.querySelectorAll('.nt-src').length;
  var totalBadges = document.querySelectorAll('.net-total-cell .nt-src').length;
  var ph = document.getElementById('netConnSearch').placeholder;
  return JSON.stringify({
    q1: q1, q2: q2, q3: q3, q4: q4, q5: q5,
    noMatch: noMatch, hint: hint,
    rows: rows, badges: badges, totalBadges: totalBadges,
    ph: ph,
    openH: d.getBoundingClientRect().height
  });
})()
"@
Assert ($r8.q1 -eq 1) '搜索进程名只保留 1 行（实际 ' + $r8.q1 + '）'
Assert ($r8.q2 -eq 1) 'UDP 筛选只保留 1 行（实际 ' + $r8.q2 + '）'
Assert ($r8.q3 -eq 1) '服务标签筛选只保留 1 行（实际 ' + $r8.q3 + '）'
Assert ($r8.q4 -eq 0 -and $r8.noMatch -eq $false) '无匹配时清空表格并显示空状态'
Assert ($r8.hint -match '0\s*/\s*(共\s*)?2') "筛选计数显示 0 / 2（实际 '$($r8.hint)'）"
Assert ($r8.q5 -eq 2) '清空筛选恢复全部 2 行'
Assert ($r8.rows -eq 4) '口径表 L1–L4 共 4 行（实际 ' + $r8.rows + '）'
Assert ($r8.badges -ge 4) '口径表每层都有来源角标'
Assert ($r8.totalBadges -eq 5) '汇总五个数字旁都有 L1 角标（实际 ' + $r8.totalBadges + '）'
Assert ($r8.ph -ne '' -and $r8.ph -notmatch 'net\.') '搜索框占位文案已渲染（不是 key）'
Assert ([double]$r8.openH -gt 80) '展开后口径表有实际高度（实际 ' + $r8.openH + '）'
$r9 = Exec "(function(){ var zh=t('net.calL1'); setLanguage('en-US'); var en=t('net.calL1'); var allOpt=document.querySelector('#netConnSvc option').textContent; setLanguage('ja-JP'); var ja=t('net.calL1'); setLanguage('zh-CN'); return JSON.stringify({ zh: zh, en: en, ja: ja, allOpt: allOpt }); })()"
Assert ($r9.zh -ne '' -and $r9.en -ne '' -and $r9.ja -ne '' -and $r9.zh -ne $r9.en -and $r9.en -ne $r9.ja) '口径表三语文案齐全（zh/en/ja 各不相同）'
Assert ($r9.allOpt -match 'All services') "语言切换后服务下拉首项也翻译（实际 '$($r9.allOpt)'）"

if ($fail -eq 0) { Ok '网络页真 WebView2 自证全部通过' } else { Write-Host "失败 $fail 项" -ForegroundColor Red }
try { $form.Dispose() } catch { }
if ($fail -gt 0) { exit 1 } else { exit 0 }
