# PerfCapture 冒烟测试：结构 / 语法 / 编码 / 依赖 / 契约
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1
$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$msg) { Write-Host "  ✅ $msg" -ForegroundColor Green }
function Bad([string]$msg) { Write-Host "  ❌ $msg" -ForegroundColor Red; $script:fail++ }
function Warn([string]$msg) { Write-Host "  ⚠ $msg" -ForegroundColor Yellow }

Write-Host "== PerfCapture 冒烟测试 ==" -ForegroundColor Cyan
Write-Host "  根目录: $root"

# ---------- 1. 结构 ----------
Write-Host "`n[1/6] 目录结构"
$structure = @(
    'src\PerfCapture.ps1',
    'src\app\00-Prelude.ps1', 'src\app\05-Paths.ps1', 'src\app\10-Bootstrap.ps1',
    'src\app\15-Logging.ps1', 'src\app\20-Settings.ps1', 'src\app\30-Tools.ps1', 'src\app\35-Metrics.ps1',
    'src\app\40-Bridge.ps1', 'src\app\50-Host.ps1', 'src\app\60-Capture.ps1', 'src\app\90-Main.ps1',
    'src\engine\Measure-GamePerf.ps1',
    'ui\index.html',
    'ui\css\tokens.css', 'ui\css\layout.css', 'ui\css\components.css',
    'ui\css\terminal.css', 'ui\css\report.css', 'ui\css\popup.css', 'ui\css\updates.css', 'ui\css\survey.css', 'ui\css\realtime.css',
    'ui\js\util.js', 'ui\js\i18n.js', 'ui\js\capture-options.js', 'ui\js\bridge.js',
    'ui\js\theme.js', 'ui\js\popup.js', 'ui\js\terminal.js', 'ui\js\ui-state.js',
    'ui\js\report.js', 'ui\js\collapse.js', 'ui\js\split.js',
    'ui\js\sidebar.js', 'ui\js\settings.js', 'ui\js\main.js',
    'ui\js\updates-data.js', 'ui\js\updates.js', 'ui\js\survey-data.js', 'ui\js\survey.js', 'ui\js\realtime.js',
    'assets\app-icon.ico', 'assets\app-icon.png',
    'lib\Microsoft.Web.WebView2.Core.dll', 'lib\Microsoft.Web.WebView2.WinForms.dll', 'lib\WebView2Loader.dll',
    'tools\presentmon.exe',
    'deps\deps.json', 'deps-inbox\说明.txt', 'capture-options.json'
)
foreach ($p in $structure) {
    if (-not (Test-Path (Join-Path $root $p))) { Bad "缺少 $p" }
}
# build\ 只在开发目录存在，分发包里没有，不做必检
if ((Test-Path (Join-Path $root 'build')) -and -not (Test-Path (Join-Path $root 'build\pack.ps1'))) {
    Bad '缺少 build\pack.ps1'
}
if ($fail -eq 0) { Ok "结构完整（$($structure.Count) 项）" }

# ---------- 2. PowerShell 语法 + BOM ----------
Write-Host "`n[2/6] PowerShell 语法与编码"
Get-ChildItem (Join-Path $root 'src') -Recurse -Filter '*.ps1' | ForEach-Object {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count) { Bad "$($_.Name) 语法错误 L$($errs[0].Extent.StartLineNumber)" }
    $b = [System.IO.File]::ReadAllBytes($_.FullName)
    if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
        Bad "$($_.Name) 缺少 UTF-8 BOM（PS 5.1 会把中文按 GBK 解析）"
    }
}
if ($fail -eq 0) { Ok "src 下所有脚本语法通过且均带 BOM" }

# ---------- 3. JS 语法 ----------
Write-Host "`n[3/6] 前端脚本语法"
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    Get-ChildItem (Join-Path $root 'ui\js') -Filter '*.js' | ForEach-Object {
        & node --check $_.FullName 2>$null
        if ($LASTEXITCODE -ne 0) { Bad "$($_.Name) 语法错误" }
    }
    if ($fail -eq 0) { Ok "ui\js 全部通过 node --check" }
} else {
    Warn '未安装 node，跳过 JS 语法检查'
}

# ---------- 4. CSS 括号配平 ----------
Write-Host "`n[4/6] CSS 括号配平"
Get-ChildItem (Join-Path $root 'ui\css') -Filter '*.css' | ForEach-Object {
    $c = Get-Content $_.FullName -Raw -Encoding UTF8
    $o = ([regex]::Matches($c, '\{')).Count
    $cl = ([regex]::Matches($c, '\}')).Count
    if ($o -ne $cl) { Bad "$($_.Name) 括号不配平（{=$o }=$cl）" }
}
if ($fail -eq 0) { Ok 'ui\css 全部配平' }

# ---------- 5. 依赖与契约 ----------
Write-Host "`n[5/6] 依赖与契约"
$deps = Get-Content (Join-Path $root 'deps\deps.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $deps.deps -or $deps.deps.Count -lt 3) { Bad 'deps.json 结构异常' }
else { Ok "deps.json 可解析，$($deps.deps.Count) 条依赖" }

$idx = Get-Content (Join-Path $root 'ui\index.html') -Raw -Encoding UTF8
foreach ($id in 'btnStart', 'btnStop', 'btnProc', 'btnExport', 'btnOpen', 'popup', 'popupList', 'term', 'preview', 'sidebarToggle', 'segTheme', 'segLang') {
    if ($idx -notmatch ('id="' + $id + '"')) { Bad "index.html 缺少 #$id" }
}
if ($fail -eq 0) { Ok 'index.html 关键节点齐全' }

$mainJs = Get-Content (Join-Path $root 'ui\js\bridge.js') -Raw -Encoding UTF8
foreach ($cmd in 'ready', 'refreshProcs', 'saveSettings', 'openReports', 'export', 'start', 'stop') {
    if ($mainJs -notmatch $cmd) { Warn "bridge.js 未出现命令 $cmd（可能只在宿主侧）" }
}

# ---------- 5b. 采集项清单契约 ----------
# capture-options.json 是唯一事实来源：每项都要能被界面渲染（label 三语齐全），
# 且 skip 值在引擎里确有对应分支。对不上直接失败，避免出现「有开关但不生效」。
$optFile = Join-Path $root 'capture-options.json'
if (Test-Path $optFile) {
    $optCfg = $null
    try { $optCfg = Get-Content $optFile -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Bad ('capture-options.json 解析失败: ' + $_.Exception.Message) }
    if ($optCfg) {
        $opts = @($optCfg.options)
        if (-not $opts.Count) { Bad 'capture-options.json 没有 options' }
        $i18nText = Get-Content (Join-Path $root 'ui\js\i18n.js') -Raw -Encoding UTF8
        $engText = Get-Content (Join-Path $root 'src\engine\Measure-GamePerf.ps1') -Raw -Encoding UTF8
        $bad = 0
        foreach ($o in $opts) {
            if (-not $o.skip -or -not $o.label) { Bad '采集项缺少 skip 或 label'; $bad++; continue }
            $n = ([regex]::Matches($i18nText, [regex]::Escape("'" + $o.label + "':"))).Count
            if ($n -lt 3) { Bad ("i18n 中 $($o.label) 只有 $n 种语言（需 3）"); $bad++ }
            if ($engText -notmatch ('-contains ''' + [regex]::Escape($o.skip) + '''')) {
                Bad ("引擎没有 skip=$($o.skip) 的采集分支"); $bad++
            }
        }
        if ($bad -eq 0) { Ok "采集项清单一致（$($opts.Count) 项 · 文案三语齐全 · 引擎分支齐全）" }
        # 界面不能再写死勾选框，否则清单驱动就失去意义
        if ($idx -match 'data-skip=') { Bad 'index.html 仍在写死采集项勾选框（应交给 capture-options.js 渲染）' }
        if ($idx -notmatch 'data-collapse=') { Bad 'index.html 缺少 data-collapse（卡片折叠）' }
        if ($idx -notmatch 'js/capture-options\.js') { Bad 'index.html 未加载 capture-options.js' }
        # 旧配置迁移：gpu / mem 两个粗开关必须仍能映射到拆分后的键（引擎 + 界面各一处）
        $optJs = Get-Content (Join-Path $root 'ui\js\capture-options.js') -Raw -Encoding UTF8
        foreach ($leg in 'gpu', 'mem') {
            if ($optJs -notmatch ("(?m)^\s*" + $leg + ":")) { Bad "capture-options.js 缺少旧键 $leg 的映射" }
        }
        if ($engText -notmatch '\$skipList \+= ''gputemp'', ''gpuusage''') { Bad '引擎缺少 skip=gpu 的旧配置映射' }
        if ($engText -notmatch '\$skipList \+= ''vram'', ''ram''') { Bad '引擎缺少 skip=mem 的旧配置映射' }
        if ($idx -notmatch 'js/collapse\.js') { Bad 'index.html 未加载 collapse.js' }
    }
}

# ---------- 5c. 拖动分割契约 ----------
$layCss = Get-Content (Join-Path $root 'ui\css\layout.css') -Raw -Encoding UTF8
$cmpCss = Get-Content (Join-Path $root 'ui\css\components.css') -Raw -Encoding UTF8
$splitJs = Get-Content (Join-Path $root 'ui\js\split.js') -Raw -Encoding UTF8
if ($idx -notmatch 'id="splitCol"') { Bad 'index.html 缺少 #splitCol' }
if ($idx -notmatch 'js/split\.js') { Bad 'index.html 未加载 split.js' }
if ($layCss -notmatch 'var\(--col-left-w') { Bad 'layout.css 未使用 --col-left-w（拖动宽度无处落）' }
if ($layCss -notmatch 'minmax\(20rem') { Bad 'layout.css 缺左栏最小宽度 20rem（钳制基准）' }
if ($layCss -notmatch 'minmax\(18rem') { Bad 'layout.css 缺右栏最小宽度 18rem（钳制基准）' }
if ($cmpCss -notmatch '\.splitter-col') { Bad 'components.css 缺 .splitter-col 样式' }
if ($splitJs -notmatch [regex]::Escape('perf.split.col')) { Bad 'split.js 未持久化 perf.split.col' }
if ($splitJs -notmatch "addEventListener\('resize'") { Bad 'split.js 未在窗口变化时重新钳制' }
if ($idx -notmatch 'role="separator"') { Bad 'index.html 缺 role="separator"（键盘可达性）' }
# 拖动灵敏度回归守卫：位移必须以按下时的宽度为基准，不能每次 move 重读当前宽度
if ($splitJs -notmatch 'startSize') { Bad 'split.js 拖动未用按下时的基准宽度（位移会被逐帧放大）' }
if ($splitJs -match 'opts\.size\(\) \+') { Bad 'split.js 仍按当前尺寸累加位移（拖动会飞）' }
# 1.4.1 起终端不再提供拖动条（终端自身有滚动条，够用了）
if ($idx -match 'splitTerm') { Bad 'index.html 仍有终端拖动条（1.4.1 已移除）' }
if ($cmpCss -match 'splitter-row') { Bad 'components.css 仍有 splitter-row 残留' }

# ---------- 5d. 终端面积与拉长契约 ----------
$termCss = Get-Content (Join-Path $root 'ui\css\terminal.css') -Raw -Encoding UTF8
$termJs = Get-Content (Join-Path $root 'ui\js\terminal.js') -Raw -Encoding UTF8
# 5b 里读过 i18n；清单缺失时可能没读，这里兜一次，避免后面 Null 引用
if (-not $i18nText) { $i18nText = Get-Content (Join-Path $root 'ui\js\i18n.js') -Raw -Encoding UTF8 }
# 拖过之后左栏是固定 px：右栏必须用 1fr 吃掉剩余空间，否则右侧会留白（看起来像右边框在动）
if ($layCss -notmatch '\.layout\.has-col-width') { Bad 'layout.css 缺 .has-col-width（拖过之后右栏未改成 1fr）' }
if ($layCss -match 'has-col-width[\s\S]{0,200}0\.82fr') { Bad '.has-col-width 里右栏仍写 0.82fr，会留白' }
if ($splitJs -notmatch "has-col-width") { Bad 'split.js 未切换 .has-col-width' }
# 终端面积固定：不能用 flex:1 吃剩余空间，日志区要有固定高度
if ($termCss -match '\.card-term \{[^}]*flex:\s*1') { Bad 'terminal.css 里 .card-term 仍用 flex:1（会随上方卡片收起展开变高）' }
if ($termCss -notmatch '\.card-term \.term \{ height:') { Bad 'terminal.css 缺终端固定高度' }
if ($termCss -notmatch '\.card-term\.is-stretched') { Bad 'terminal.css 缺拉长样式' }
if ($termCss -notmatch '\.col-left\.is-term-stretched') { Bad 'terminal.css 缺拉长时锁滚动的规则' }
# 终端的两个按钮与逻辑
foreach ($nid in 'cardTerm', 'termStretch') {
    if ($idx -notmatch ('id="' + $nid + '"')) { Bad "index.html 缺少 #$nid" }
}
if ($idx -notmatch 'data-collapse="term"') { Bad 'index.html 终端卡未接入折叠（data-collapse="term"）' }
if ($idx -notmatch 'card-title-actions') { Bad 'index.html 缺标题按钮组' }
if ($termJs -notmatch 'is-stretched') { Bad 'terminal.js 缺拉长切换逻辑' }
foreach ($tk in 'term.stretch', 'term.restore') {
    $n = ([regex]::Matches($i18nText, [regex]::Escape("'" + $tk + "':"))).Count
    if ($n -lt 3) { Bad "i18n 中 $tk 只有 $n 种语言（需 3）" }
}
# 拉长必须覆盖左栏（目标进程以下），所以左栏要能当定位基准
if ($layCss -notmatch '\.col-left \{[^}]*position:\s*relative') { Bad 'layout.css 的 .col-left 缺 position:relative（拉长无处定位）' }

# ---------- 5e. 图表悬浮契约 ----------
$repJs = Get-Content (Join-Path $root 'ui\js\report.js') -Raw -Encoding UTF8
$mainJsAll = Get-Content (Join-Path $root 'ui\js\main.js') -Raw -Encoding UTF8
# 底图缓存 + overlay：底图只画一次，悬浮时贴回去再画十字线，不能每次 mousemove 重绘整条曲线
if ($repJs -notmatch 'chartStore') { Bad 'report.js 缺图表底图缓存（chartStore）' }
if ($repJs -notmatch 'function paintChartBase') { Bad 'report.js 缺底图回贴函数（paintChartBase）' }
if ($repJs -notmatch 'function drawChartHover') { Bad 'report.js 缺悬浮层绘制（drawChartHover）' }
if ($repJs -notmatch "pointermove") { Bad 'report.js 未绑定图表 pointermove' }
if ($mainJsAll -notmatch 'redrawCharts') { Bad 'main.js 窗口变化时未重画图表（redrawCharts）' }
foreach ($hk in 'chart.hover.time', 'chart.hover.fps', 'chart.hover.avgFt', 'chart.hover.eqFps', 'chart.hover.slowFt') {
    $n = ([regex]::Matches($i18nText, [regex]::Escape("'" + $hk + "':"))).Count
    if ($n -lt 3) { Bad "i18n 中 $hk 只有 $n 种语言（需 3）" }
}

# ---------- 5f. 导出长图契约 ----------
$capPs = Get-Content (Join-Path $root 'src\app\60-Capture.ps1') -Raw -Encoding UTF8
$brPs = Get-Content (Join-Path $root 'src\app\40-Bridge.ps1') -Raw -Encoding UTF8
$repCss = Get-Content (Join-Path $root 'ui\css\report.css') -Raw -Encoding UTF8
$mainJs2 = Get-Content (Join-Path $root 'ui\js\main.js') -Raw -Encoding UTF8
$brJs = Get-Content (Join-Path $root 'ui\js\bridge.js') -Raw -Encoding UTF8
if ($idx -notmatch 'id="btnExportPng"') { Bad 'index.html 缺少 #btnExportPng' }
if ($capPs -notmatch "'exportPng'" ) { Bad '60-Capture.ps1 白名单缺 exportPng' }
if ($capPs -notmatch 'Page\.captureScreenshot') { Bad '宿主未使用 Page.captureScreenshot' }
if ($capPs -notmatch 'captureBeyondViewport') { Bad '截图缺 captureBeyondViewport（长图会被截断）' }
if ($capPs -notmatch 'function Get-PngClip') { Bad '缺 clip/缩放计算（16384px 上限）' }
if ($capPs -notmatch "pngDone") { Bad '宿主导出结束未回 pngDone（界面会卡在导出视图）' }
if ($brPs -notmatch 'function Invoke-DevTools') { Bad '40-Bridge.ps1 缺 CDP 调用封装' }
if ($brPs -notmatch 'DoEvents') { Bad 'CDP 等待没有泵消息（会死锁）' }
if ($repCss -notmatch 'html\.is-exporting') { Bad 'report.css 缺导出视图样式' }
# 导出视图由宿主在弹完保存对话框后调 setExportView 切换（main.js 不再自己切）
if ($repJs -notmatch 'function setExportView') { Bad 'report.js 缺 setExportView（宿主无法切导出视图）' }
if ($mainJs2 -match "classList\.add\('is-exporting'\)") { Bad 'main.js 又自己切导出视图（点击会先被放大再等对话框）' }
if ($brPs -notmatch 'function Invoke-UiScript') { Bad '40-Bridge.ps1 缺 Invoke-UiScript（宿主无法调前端切视图）' }
if ($brPs -notmatch 'ExecuteScriptAsync') { Bad 'Invoke-UiScript 未用 ExecuteScriptAsync' }
# 导出顺序：保存对话框 → 窗口设为全透明（不 Hide！） → 切导出视图 → 截图 → 还原视图 → 恢复不透明度
# 反了就会出现「窗口先被放大，几秒后才弹框」；藏不住就会看到版面被撑开的那一瞬。
$pngFn = [regex]::Match($capPs, '(?s)function Export-ReportPng \{.*?\n\}').Value
if (-not $pngFn) { Bad '找不到 Export-ReportPng 函数体' }
else {
    $iDlg = $pngFn.IndexOf('ShowDialog')
    $iDim = $pngFn.IndexOf('$form.Opacity = 0')
    $iView = $pngFn.IndexOf('setExportView(true)')
    $iShot = $pngFn.IndexOf('Page.captureScreenshot')
    if ($iDlg -lt 0 -or $iShot -lt 0) { Bad 'Export-ReportPng 缺保存对话框或截图调用' }
    elseif ($iDlg -gt $iDim -or $iDlg -gt $iShot) { Bad '导出顺序错了：保存对话框必须最先弹' }
    if ($iDim -lt 0) { Bad '导出前没有把窗口设为全透明（选完路径会看到版面被撑开）' }
    elseif ($iDim -gt $iView -or $iDim -gt $iShot) { Bad '设为全透明必须在切视图与截图之前' }
    if ($iView -lt 0 -or $iView -gt $iShot) { Bad '导出顺序错了：setExportView(true) 必须在截图之前' }
    if ($pngFn -notmatch 'setExportView\(false\)') { Bad '导出结束未还原视图（出错会卡在导出视图）' }
    if ($pngFn -notmatch '\$form\.Opacity = 1') { Bad '导出结束未恢复不透明度（窗口会一直看不见）' }
    # 还原视图必须在恢复不透明度之前，否则用户仍会看到版面跳动
    $iRestore = $pngFn.IndexOf('setExportView(false)')
    $iBack = $pngFn.IndexOf('$form.Opacity = 1')
    if ($iRestore -lt 0 -or $iBack -lt 0 -or $iRestore -gt $iBack) { Bad '还原顺序错了：先 setExportView(false) 再恢复不透明度' }
}
# 绝对不能在导出期间 Hide 主窗口：它是 ShowDialog 模态循环，Visible=false 会让循环结束、
# 程序自己关掉（1.8.1 实测事故）。最小化也不行（CDP 调用会挂住）。
if ($pngFn -match '\$form\.Hide\(\)') { Bad '导出期间调用了 $form.Hide()（ShowDialog 会直接退出，程序自己关掉）' }
if ($pngFn -match 'ShowWindow|SW_HIDE|SW_SHOWNOACTIVATE') { Bad '导出期间用了 ShowWindow/SW_HIDE（同样会让模态循环结束）' }
if ($pngFn -match "WindowState\s*=\s*'Minimized'") { Bad '导出期间最小化窗口会让 CDP 调用挂住' }
if ($capPs -notmatch 'ShowDialog') { Bad '60-Capture.ps1 里没有 ShowDialog 相关逻辑（主界面是模态窗口）' }
# 兜底：导出结束必须确认窗口还可见（模态循环的条件就是"仍可见"，不可见 = 程序退出）
if ($pngFn -notmatch '\$form\.Visible') { Bad '导出结束没有检查窗口可见性（窗口可能被留成不可见 → 程序退出）' }
# 主循环层再兜一层：ShowDialog 不是被用户关掉而返回时，重新进入
$mainPs = Get-Content (Join-Path $root 'src\app\90-Main.ps1') -Raw -Encoding UTF8
# 导出期间主窗口是全透明的：必须有"正在导出"的提示窗，否则用户会以为程序挂了
if ($capPs -notmatch 'function Show-ExportToast') { Bad '60-Capture.ps1 缺导出提示窗（Show-ExportToast）' }
if ($capPs -notmatch 'function Hide-ExportToast') { Bad '60-Capture.ps1 缺提示窗收尾（Hide-ExportToast）' }
$iToast = $pngFn.IndexOf('Show-ExportToast')
$iDim = $pngFn.IndexOf('$form.Opacity = 0')
if ($iToast -lt 0) { Bad 'Export-ReportPng 没有弹出导出提示窗' }
elseif ($iDim -ge 0 -and $iToast -gt $iDim) { Bad '提示窗必须在窗口变全透明之前弹出' }
$iHide = $pngFn.IndexOf('Hide-ExportToast')
if ($iHide -lt 0) { Bad 'Export-ReportPng 结束没有关掉提示窗（会一直挂在屏幕上）' }
elseif ($iHide -gt $pngFn.IndexOf("type = 'pngDone'")) { Bad '提示窗必须在回执 pngDone 之前关掉' }
foreach ($tk in '正在导出报告长图', 'Exporting report image', 'レポート画像を書き出しています') {
    if ($capPs -notmatch [regex]::Escape($tk)) { Bad "提示窗文案缺 $tk" }
}
if ($mainPs -notmatch 'UserClosed') { Bad '90-Main.ps1 缺"是否被用户关闭"的标记（无法判断模态循环是否意外返回）' }
if ($mainPs -notmatch 'while \(-not \$form\.IsDisposed') { Bad '90-Main.ps1 主循环没有"意外返回就重进"的保护' }
# 长图里不能带设置页（外观 / 通用 / 关于）
if ($repCss -notmatch '\.page\[data-page="capture"\]') { Bad '导出视图没限定采集页（设置页会进长图）' }
if ($repCss -match '(?m)^html\.is-exporting \.page \{') { Bad '导出视图仍有通用 .page 规则（覆盖 [hidden]，设置页进长图）' }
if ($brJs -notmatch "case 'pngDone'") { Bad 'bridge.js 未处理 pngDone' }
# 导出动作必须在回调外执行：回调里调 CDP 必超时（实测），界面会卡在导出视图
if ($capPs -notmatch 'function Queue-Export') { Bad '60-Capture.ps1 缺导出排队（Queue-Export）' }
if ($capPs -notmatch 'BeginInvoke') { Bad '导出未排到消息循环（BeginInvoke）' }
# 消息开关里必须只排队：直接调用 Export-ReportPng 会卡死（CDP 在回调里不完成）
$switchBlock = [regex]::Match($capPs, '(?s)switch \(\$msg\.cmd\).*?\n\s{8}\}').Value
if ($switchBlock -match 'Export-ReportPng|Export-Report\b') { Bad '消息开关里仍直接执行导出（应只 Queue-Export）' }
# 导出的 HTML：位图必须取自**原画布**（克隆的 canvas 是空的）
if ($repJs -notmatch 'const live = src\.querySelectorAll') { Bad 'report.js 导出时未取原画布（克隆 canvas 无位图）' }
if ($repJs -notmatch 'from\.toDataURL') { Bad 'report.js 仍在克隆 canvas 上取 toDataURL（导出图会是空框）' }
# 导出视图不能改背景：长图要与窗口一致
if ($repCss -match 'is-exporting body \{[^}]*background:') { Bad '导出视图改了页面背景（长图会与窗口外观不一致）' }
if ($repJs -notmatch 'function exportBackground') { Bad '导出 HTML 未内联背景图（外观与窗口不一致）' }
# 导出 HTML 的图表：canvas 位图不会被序列化，必须换成 img
if ($repJs -notmatch 'toDataURL') { Bad 'report.js 导出 HTML 时未把 canvas 换成位图（图表会是空框）' }
if ($repJs -notmatch '\.rp-chart img') { Bad '导出模板缺 .rp-chart img 样式' }
foreach ($ek in 'capture.exportPng') {
    $n = ([regex]::Matches($i18nText, [regex]::Escape("'" + $ek + "':"))).Count
    if ($n -lt 3) { Bad "i18n 中 $ek 只有 $n 种语言（需 3）" }
}

# ---------- 5g. 1% Low 判定与报告展示契约 ----------
# 1% Low 新定义：丢掉最差的一帧再取剩余最差 1%（单次尖峰不该定义整个下限），
# 判定改看「帧率落回 1% Low 的频率」，占平均的百分比只做展示。
$engPs = Get-Content (Join-Path $root 'src\engine\Measure-GamePerf.ps1') -Raw -Encoding UTF8
if ($engPs -notmatch '\$sorted\s*=\s*@\(\$frameTimes \| Sort-Object -Descending\)') { Bad '引擎 1% Low 前提变了：$sorted 必须是降序（最差在前）' }
if ($engPs -notmatch 'Select-Object -Skip 1') { Bad '引擎 1% Low 未丢掉最差的一帧' }
if ($engPs -notmatch 'lowHitsPct') { Bad '引擎缺落回频率统计（lowHitsPct）' }
foreach ($jk in 'fps_1pct_low_pct', 'low_hits_pct') {
    if ($engPs -notmatch $jk) { Bad "JSON 契约缺 $jk" }
}
foreach ($vk in 'verdict.low.smooth', 'verdict.low.occasional', 'verdict.low.frequent') {
    if ($engPs -notmatch [regex]::Escape("'" + $vk + "'")) { Bad "引擎未发出 $vk" }
    $n = ([regex]::Matches($i18nText, [regex]::Escape("'" + $vk + "':"))).Count
    if ($n -lt 3) { Bad "i18n 中 $vk 只有 $n 种语言（需 3）" }
}
# 旧判定键保留只为旧报告查表，引擎不能再发出（否则新报告会查不到文案）
if ($engPs -match 'verdict\.low\.(unstable|stutter|stable)') { Bad '引擎仍发出旧的 1% Low 判定键' }
# 判定说明是「落回 1% Low **附近**」：附近 10%（$lowNearPct）纳入统计
if ($engPs -notmatch '\$lowNearPct = 10') { Bad '引擎缺「附近 10%」的阈值定义（$lowNearPct）' }
if ($engPs -notmatch '1\.0 \+ \$lowNearPct / 100\.0') { Bad '引擎的落回阈值没用 $lowNearPct（附近 10%）' }
$nNear = ([regex]::Matches($i18nText, '1% Low 付近|near 1% Low|1% Low 附近')).Count
# 占比直接显示在 1% Low 数值右侧，且与单位（FPS）同样式，不是数值那种大字
if ($nNear -lt 9) { Bad "判定文案没有统一写成「落回 1% Low 附近」（只匹配到 $nNear 处，应为 9 = 3 键 × 3 语种）" }
if ($repJs -notmatch 'fps_1pct_low_pct') { Bad 'report.js 未把占比接到 1% Low 数值右侧' }
if ($repJs -notmatch 'class="p"') { Bad 'report.js 缺占比的 .p 标记' }
if ($repCss -notmatch '(?s)\.rp-tile \.v small,\s*\n\.rp-tile \.v \.p \{') { Bad 'report.css 里占比没有和单位（small）共用同一套样式' }
if ($engPs -notmatch '\.card \.p\{font-size:12px;color:\$cMuted') { Bad '引擎 HTML 的 .card .p 没有跟单位（.card .u）同样式' }

# ---------- 5h. 更新公告 / 实时监控入口 ----------
$dataJs = Get-Content (Join-Path $root 'ui\js\updates-data.js') -Raw -Encoding UTF8
$updJs = Get-Content (Join-Path $root 'ui\js\updates.js') -Raw -Encoding UTF8
$verFile = (Get-Content (Join-Path $root 'VERSION') -Raw -Encoding UTF8).Trim()
# 侧边栏：功能区（采集 / 实时监控）+ 底部组（更新公告 / 设置）+ 版本号
$navBlock = [regex]::Match($idx, '(?s)<nav class="sidebar-nav">.*?</nav>').Value
$navPages = [regex]::Matches($navBlock, 'data-page="([a-z]+)"') | ForEach-Object { $_.Groups[1].Value }
if ($navPages.Count -lt 4) { Bad "侧边栏只有 $($navPages.Count) 项（应有采集 / 实时监控 / 更新公告 / 设置）" }
elseif ($navPages[1] -ne 'realtime' -or $navPages[2] -ne 'updates') { Bad "侧边栏顺序不对：$($navPages -join ' → ')" }
if ($navBlock -match 'nav-badge') { Bad '侧边栏里还挂着「待开发」徽标（应只在实时监控页里）' }
if ($navBlock -match '待开发') { Bad '侧边栏文字里出现了「待开发」' }
# 底部两组：功能区与底部组必须分开，底部组里放更新公告 + 设置 + 版本号
if ($navBlock -notmatch 'nav-group') { Bad '侧边栏没有分组（功能区 / 底部组）' }
$bottomBlock = [regex]::Match($navBlock, '(?s)<div class="nav-group nav-group-bottom">.*?</div>\s*</nav>').Value
if (-not $bottomBlock) { Bad '侧边栏缺底部组（nav-group-bottom）' }
else {
    foreach ($need in 'data-page="updates"', 'data-page="settings"', 'sidebar-version') {
        if ($bottomBlock -notmatch [regex]::Escape($need)) { Bad "侧边栏底部组缺 $need" }
    }
}
if ($idx -notmatch ('id="sidebarVersion">v' + [regex]::Escape($verFile))) { Bad "侧边栏底部版本号不是 v$verFile" }
if ($layCss -notmatch '\.app\.is-collapsed \.sidebar-version \{ display: none') { Bad '侧边栏收起时没有隐藏版本号' }
# 设置图标必须是齿轮（含齿形路径，而不是旧的那个发光线圈）
$gearBlock = [regex]::Match($idx, '(?s)data-page="settings".*?</button>').Value
if ($gearBlock -notmatch 'a1\.9 1\.9 0 1 1') { Bad '设置图标的齿轮路径没换（仍是旧图标）' }
foreach ($pg in 'realtime', 'updates') {
    if ($idx -notmatch ('<section class="page" data-page="' + $pg + '"')) { Bad "index.html 缺少 $pg 页面" }
}
if ($idx -notmatch 'data-i18n="nav\.realtime"') { Bad 'index.html 侧边栏缺实时监控项' }
if ($idx -notmatch 'data-i18n="nav\.updates"') { Bad 'index.html 侧边栏缺更新公告项' }
# 页面资源必须真的加载（数据先于渲染脚本）
if ($idx -notmatch 'css/updates\.css') { Bad 'index.html 未加载 updates.css' }
$iData = $idx.IndexOf('js/updates-data.js')
$iRender = $idx.IndexOf('js/updates.js')
if ($iData -lt 0) { Bad 'index.html 未加载 updates-data.js' }
if ($iRender -lt 0) { Bad 'index.html 未加载 updates.js' }
if ($iData -ge 0 -and $iRender -ge 0 -and $iData -gt $iRender) { Bad 'updates-data.js 必须在 updates.js 之前加载' }
# 数据：版本线只到「主.次」（1.1 / 1.2），条目不写时间、只写日期
if ($dataJs -notmatch 'window\.PerfUpdates') { Bad 'updates-data.js 缺 window.PerfUpdates' }
if ($dataJs -notmatch 'window\.PerfUpdateVersions') { Bad 'updates-data.js 缺 window.PerfUpdateVersions' }
if ($dataJs -match "time:\s*'") { Bad '更新公告数据里还有 time 字段（应只写日期）' }
if ($dataJs -match 'approx') { Bad '更新公告数据里还有 approx（约等于时间已取消）' }
$verList = [regex]::Matches($dataJs, "version:\s*'([0-9.]+)',\s*date:") | ForEach-Object { $_.Groups[1].Value }
if ($verList.Count -lt 4) { Bad "版本记录至少应有四条（1.1 起），实际 $($verList.Count) 条" }
elseif (($verList -join ',') -ne (($verList | Sort-Object -Descending { [version]($_ + '.0') }) -join ',')) {
    Bad "版本记录顺序不对（应新→旧）：$($verList -join ' , ')"
}
if ($verList -notcontains '1.5' -and $verFile -match '^1\.5\.') { Bad '1.5 版本线缺失（当前版本是 1.5.x）' }
if ($dataJs -notmatch "version: '1\.4', date: '2026-11-16'") { Bad '1.4 版本线的发布日期不是 2026-11-16' }
if ($dataJs -notmatch "version: '1\.3', date: '2026-11-15'") { Bad '1.3 版本线的发布日期不是 2026-11-15' }
if ($dataJs -notmatch [regex]::Escape("version: '$verFile'")) { Bad "updates-data.js 里没有当前版本 $verFile 的条目" }
$entryVers = [regex]::Matches($dataJs, "version: '(\d+\.\d+)\.\d+'") | ForEach-Object { $_.Groups[1].Value }
if ($entryVers.Count -lt 4) { Bad "条目版本号不够（应为 1.1.x / 1.2.x 多条），实际 $($entryVers.Count)" }
# 版本线列表必须覆盖所有条目（新增版本线时忘记登记会在这里被抓住）
if (($entryVers | Where-Object { $verList -notcontains $_ }).Count) {
    Bad ("这些条目的版本线没登记进 PerfUpdateVersions：" + (($entryVers | Where-Object { $verList -notcontains $_ } | Sort-Object -Unique) -join ' , '))
}
# 条目分类 = 改动方向（PerfUpdateCategories 声明的九个键），不再是侧边栏功能区
if ($dataJs -notmatch 'window\.PerfUpdateCategories') { Bad 'updates-data.js 缺 PerfUpdateCategories（分类表）' }
$catList = [regex]::Match($dataJs, '(?s)window\.PerfUpdateCategories = \[(.*?)\]').Groups[1].Value
$catKeys = [regex]::Matches($catList, "'([a-z]+)'") | ForEach-Object { $_.Groups[1].Value }
if ($catKeys.Count -ne 9) { Bad "分类表应有九项，实际 $($catKeys.Count) 项" }
foreach ($need in 'feature', 'ui', 'ux', 'fix', 'metrics', 'chart', 'install', 'compat', 'survey') {
    if ($catKeys -notcontains $need) { Bad "分类表缺 $need" }
}
$itemKeys = [regex]::Matches($dataJs, "(?m)^\s*\['([a-z]+)',") | ForEach-Object { $_.Groups[1].Value }
if (-not $itemKeys.Count) { Bad '更新公告条目没有分类键' }
$badKeys = $itemKeys | Where-Object { $catKeys -notcontains $_ } | Select-Object -Unique
if ($badKeys) { Bad "条目用了分类表外的键：$($badKeys -join ',')" }
if (($catKeys.Count -eq 9) -and -not $badKeys) { Ok "条目分类都是改动方向（$(@($itemKeys | Select-Object -Unique) -join ' / ')）" }
# 板块：条目第三位必须在 PerfUpdateAreas 里（只用于筛选，不显示在条目里）
if ($dataJs -notmatch 'window\.PerfUpdateAreas') { Bad 'updates-data.js 缺 PerfUpdateAreas（板块表）' }
$areaList = [regex]::Match($dataJs, '(?s)window\.PerfUpdateAreas = \[(.*?)\]').Groups[1].Value
$areaKeys = [regex]::Matches($areaList, "'([a-z]+)'") | ForEach-Object { $_.Groups[1].Value }
if (($areaKeys -join ',') -ne 'capture,realtime,other') { Bad "板块表不对：$($areaKeys -join ',')" }
$badAreas = [regex]::Matches($dataJs, ",\s*'([a-z]+)'\]") | ForEach-Object { $_.Groups[1].Value } | Where-Object { $areaKeys -notcontains $_ } | Select-Object -Unique
if ($badAreas) { Bad "条目用了板块表外的键：$($badAreas -join ',')" }
$areaTagged = ([regex]::Matches($dataJs, "(?m)^\s*\['[a-z]+',.+'(capture|realtime|other)'\],?\s*$")).Count
if ($areaTagged -ne $itemKeys.Count) { Bad "条目板块标注数量不对：$areaTagged / $($itemKeys.Count)（每条都要标）" }
else { Ok "每条改动都标了板块（$areaTagged / $($itemKeys.Count)）" }
# 关于页的版本号必须跟着 VERSION 走
if ($idx -notmatch [regex]::Escape("v$verFile")) { Bad "关于页版本号没跟上 VERSION（应为 v$verFile）" }
# 渲染脚本要点：齿轮/版本条/日期栏/滚动联动/语言切换重画
if ($updJs -notmatch 'function syncScroll') { Bad 'updates.js 缺滚动联动' }
if ($updJs -notmatch 'version-link') { Bad 'updates.js 的版本条没有用 version-link（TextAxis 的卡片式尺寸）' }
if ($updJs -notmatch 'date-release') { Bad 'updates.js 的日期栏没有版本徽标（date-release）' }
if ($updJs -notmatch 'majorMinor') { Bad 'updates.js 没有把版本号截到「主.次」' }
if ($updJs -notmatch 'PerfUpdateCategories') { Bad 'updates.js 的分类没有跟 PerfUpdateCategories 走' }
if ($updJs -match 'nav-group') { Bad 'updates.js 还在从侧边栏 DOM 取分类（应只读数据表）' }
if ($updJs -notmatch 'activeArea') { Bad 'updates.js 没有板块筛选状态（activeArea）' }
if ($updJs -notmatch 'it\[2\]') { Bad 'updates.js 没按 items[2] 取板块' }
if ($updJs -notmatch 'activeCat === UPDATES_ALL \|\| it\[0\]') { Bad 'updates.js 没把分类与板块一起过滤（取交集）' }
if ($idx -notmatch 'id="updatesAreas"') { Bad 'index.html 缺板块筛选容器（#updatesAreas）' }
$iAreaRow = $idx.IndexOf('id="updatesAreas"')
$iCatRow = $idx.IndexOf('id="updatesFilters"')
if ($iAreaRow -ge 0 -and $iCatRow -ge 0) {
    if ($iAreaRow -gt $iCatRow) { Bad '板块筛选必须在分类筛选上面' }
    else { Ok '板块筛选在版本记录下面、分类筛选上面（两行同级）' }
}
if ($updJs -notmatch '__refreshUpdates') { Bad 'updates.js 未暴露 __refreshUpdates（语言切换后不会重画）' }
if ($i18nText -notmatch '__refreshUpdates') { Bad 'i18n.js 的语言切换没有触发更新公告重画' }
foreach ($uk in 'nav.realtime', 'nav.updates', 'updates.title', 'updates.noteLabel', 'updates.dayLabel', 'updates.latest', 'updates.cat.feature', 'updates.cat.ui', 'updates.cat.ux', 'updates.cat.fix', 'updates.cat.metrics', 'updates.cat.chart', 'updates.cat.install', 'updates.cat.compat', 'updates.cat.survey', 'updates.allAreas', 'updates.filterArea', 'updates.filterKind', 'updates.area.capture', 'updates.area.realtime', 'updates.area.other') {
    $n = ([regex]::Matches($i18nText, [regex]::Escape("'" + $uk + "':"))).Count
    if ($n -lt 3) { Bad "i18n 中 $uk 只有 $n 种语言（需 3）" }
}

# ---------- 5i. 安装分发 ----------
$pathsPs = Get-Content (Join-Path $root 'src\app\05-Paths.ps1') -Raw -Encoding UTF8
# build\ 只在开发目录存在（分发包里没有），与上面 pack.ps1 的检查同样处理
$hasBuild = Test-Path (Join-Path $root 'build')
$packPs = ''
$setupCore = Join-Path $root 'build\setup-core.cs'
$setupUi = Join-Path $root 'build\setup-ui.cs'
if ($hasBuild) {
    $packPs = Get-Content (Join-Path $root 'build\pack.ps1') -Raw -Encoding UTF8
    if (-not (Test-Path $setupCore)) { Bad '缺少 build\setup-core.cs（安装器主体）' }
    if (-not (Test-Path $setupUi)) { Bad '缺少 build\setup-ui.cs（安装向导界面）' }
}
# 数据目录：配置与报告必须放在 %LOCALAPPDATA%\PerfCapture，并保留旧位置迁移
if ($pathsPs -notmatch '\$script:DataDir = Join-Path \$env:LOCALAPPDATA ''PerfCapture''') { Bad '05-Paths.ps1 没有把数据目录切到 %LOCALAPPDATA%\PerfCapture' }
if ($pathsPs -notmatch '\$script:OutDir\s+= Join-Path \$script:DataDir') { Bad '05-Paths.ps1 的 OutDir 不在数据目录下' }
if ($pathsPs -notmatch '\$script:CfgPath = Join-Path \$script:DataDir') { Bad '05-Paths.ps1 的 CfgPath 不在数据目录下' }
if ($pathsPs -notmatch 'legacyCfg' -or $pathsPs -notmatch 'legacyRep') { Bad '05-Paths.ps1 缺旧数据目录迁移（legacyCfg / legacyRep）' }
# 打包脚本必须能出安装包（仅开发目录）
if ($hasBuild) {
    if ($packPs -notmatch 'PerfCapture-Setup-') { Bad 'pack.ps1 没有生成安装包（PerfCapture-Setup-<ver>.exe）' }
    if ($packPs -notmatch '/resource:') { Bad 'pack.ps1 没有把 payload 内嵌进安装器（/resource:）' }
    if ($packPs -notmatch 'ZipFile\]::CreateFromDirectory') { Bad 'pack.ps1 没有生成 payload.zip' }
    if ($packPs -notmatch "setup-core\.cs" -or $packPs -notmatch "setup-ui\.cs") { Bad 'pack.ps1 编译安装器时没带上 setup 源码' }
}
if (Test-Path $setupCore) {
    $sc = Get-Content $setupCore -Raw -Encoding UTF8
    foreach ($need in '/S', '/D=', '/U', 'payload.zip', 'Uninstall\PerfCapture', 'WScript.Shell', 'uninstall.exe', 'QuietUninstallString') {
        if ($sc -notmatch [regex]::Escape($need)) { Bad "安装器缺少 $need" }
    }
    if ($sc -notmatch 'LocalApplicationData') { Bad '安装器没把默认安装位置放在 %LOCALAPPDATA%\Programs' }
}
if (Test-Path $setupUi) {
    $su = Get-Content $setupUi -Raw -Encoding UTF8
    # 五页标题（Inno Setup 传统向导）
    foreach ($title in '欢迎使用 ', '选择目标位置', '选择附加任务', '正在安装', '正在完成') {
        if ($su -notmatch [regex]::Escape($title)) { Bad "安装向导缺页面标题：$title" }
    }
    foreach ($btn in '上一步', '下一步', '取消', '完成', '创建桌面快捷方式', '创建开始菜单快捷方式', '打开安装目录') {
        if ($su -notmatch [regex]::Escape($btn)) { Bad "安装向导缺控件文案：$btn" }
    }
    if ($su -notmatch 'progressBar') { Bad '安装向导没有进度条' }
}

# ---------- 5j. 1.3.1：DPI 只缩放一次 + 单实例不再误报 ----------
# 同一个家族问题：进程已是 PerMonitorV2 感知后，字号再乘 DpiScale / WinForms 再 AutoScale /
# 独立 exe 缺清单被位图拉伸，三种都会让窗口"发糊"。各钉一条断言，防止退化。
$bootstrap = Get-Content (Join-Path $root 'src\app\10-Bootstrap.ps1') -Raw -Encoding UTF8
# 提权必须排在抢单实例锁之前：否则被提权的子进程会和还没退出的父进程抢锁 → 误报"已经在运行"
$iAdmin = $bootstrap.IndexOf('BuiltInRole]::Administrator')
$iMutex = $bootstrap.IndexOf('PerfCapture.SingleInstance')
if ($iAdmin -lt 0 -or $iMutex -lt 0) { Bad '10-Bootstrap.ps1 找不到提权或单实例锁' }
elseif ($iAdmin -gt $iMutex) { Bad '10-Bootstrap.ps1 先抢单实例锁再提权（会误报"已经在运行"）' }
else { Ok '提权排在单实例锁之前' }
if ($bootstrap -notmatch 'AbandonedMutexException') { Bad '10-Bootstrap.ps1 没处理 AbandonedMutexException（废弃锁被当成"已在运行"）' }
if ($bootstrap -notmatch 'Local\\PerfCapture\.SingleInstance') { Bad '单实例锁不在 Local\ 作用域' }

$capPs = Get-Content (Join-Path $root 'src\app\60-Capture.ps1') -Raw -Encoding UTF8
if ($capPs -notmatch "AutoScaleMode = 'None'") { Bad '导出提示窗没有 AutoScaleMode = None（WinForms 会二次缩放，发糊）' }
if ($capPs -match 'Get-ToastFont \(11\.5 \*') { Bad '导出提示窗字号又乘了 DpiScale（二次放大，发糊）' }
if ($capPs -notmatch 'Get-ToastFont 11\.5') { Bad '导出提示窗标题字号不是固定 11.5pt' }
if ($capPs -notmatch 'UseCompatibleTextRendering = \$false') { Bad '导出提示窗没有走 GDI 渲染（ClearType）' }
if ($su -and $su -notmatch 'AutoScaleMode = AutoScaleMode\.None') { Bad '安装向导没有 AutoScaleMode = None' }

if ($hasBuild) {
    $mani = Join-Path $root 'build\setup-dpi.manifest'
    if (-not (Test-Path $mani)) { Bad '缺少 build\setup-dpi.manifest（安装包 DPI 清单）' }
    else {
        $mt = Get-Content $mani -Raw -Encoding UTF8
        if ($mt -notmatch 'PerMonitorV2') { Bad '安装包清单没声明 PerMonitorV2（整窗会被位图拉伸）' }
        if ($mt -notmatch 'Common-Controls') { Bad '安装包清单没 Common-Controls 6.0（按钮会是 Win95 立体边框）' }
        else { Ok '安装包清单：PerMonitorV2 + Common-Controls 6.0' }
    }
    if ($packPs -notmatch '/win32manifest') { Bad 'pack.ps1 编译安装包时没编清单（/win32manifest）' }
    if ($packPs -notmatch 'setup-dpi\.manifest') { Bad 'pack.ps1 的必需文件清单里没有 setup-dpi.manifest' }
}

# ---------- 5l. 字体缺失回落 ----------
$tokensCss = Get-Content (Join-Path $root 'ui\css\tokens.css') -Raw -Encoding UTF8
if ($tokensCss -notmatch 'font-display:\s*swap') { Bad 'tokens.css 的 @font-face 没写 font-display: swap（字体缺失时会空白一段）' }
if ($tokensCss -notmatch "'PerfFont',\s*'Microsoft YaHei UI'") { Bad 'tokens.css 的字体栈缺 Microsoft YaHei UI 回落' }
$termCss = Get-Content (Join-Path $root 'ui\css\terminal.css') -Raw -Encoding UTF8
if ($termCss -notmatch "'PerfFont',\s*'Microsoft YaHei UI'") { Bad 'terminal.css 的字体栈缺回落字体' }
if ($capPs -notmatch '方正兰亭圆_GBK_中粗\.ttf') { Bad '60-Capture.ps1 没有检查内置字体是否存在' }
if ($capPs -notmatch '未找到内置字体') { Bad '60-Capture.ps1 字体缺失时没给提示（终端与日志都要说）' }
if ($capPs -notmatch "'Microsoft YaHei UI',\s*\[single\]") { Bad '导出提示窗的字体没有回落到 Microsoft YaHei UI' }

# 交付：仓库必备文件（只在开发目录检查，dist 里没有 .gitignore）
if ($hasBuild) {
    foreach ($gf in '.gitignore', '.gitattributes') {
        if (-not (Test-Path (Join-Path $root $gf))) { Bad "缺少 $gf（GitHub 交付必备）" }
    }
    $gi = Get-Content (Join-Path $root '.gitignore') -Raw -Encoding UTF8
    foreach ($need in '/dist/', '/reports/', 'PerfCapture.settings.json') {
        if ($gi -notmatch [regex]::Escape($need)) { Bad ".gitignore 没有排除 $need" }
    }
    foreach ($keep in '/lib/', '/tools/', '/assets/', '/src/') {
        if ($gi -match ('(?m)^' + [regex]::Escape($keep))) { Bad ".gitignore 把必需目录 $keep 也排除了" }
    }
}

# 版本：三段十进制；前两位由用户通知才动，修补位每轮 +1
if ($verFile -notmatch '^\d+\.\d+\.\d+$') { Bad "VERSION 不是三段式：$verFile" }
if ($idx -notmatch [regex]::Escape("v$verFile")) { Bad "侧边栏版本号与 VERSION 不一致（$verFile）" }
if ($dataJs -notmatch ("date: '\d{4}-\d{2}-\d{2}', version: '" + [regex]::Escape($verFile) + "'")) { Bad "更新公告首条版本不是 $verFile" }
if ($dataJs -notmatch "version: '1\.3\.10'") { Bad '更新公告里 1.3.10 的条目被删了' }
if ($dataJs -notmatch "version: '1\.3\.9'") { Bad '更新公告里 1.3.9 的条目被删了' }
if ($dataJs -notmatch "version: '1\.3\.8'") { Bad '更新公告里 1.3.8 的条目被删了' }
if ($dataJs -notmatch "version: '1\.3\.0'") { Bad '更新公告里 1.3.0 的条目被删了' }

# ---------- 5k. 问卷调查页（本轮纯前端） ----------
$surveyJs = Get-Content (Join-Path $root 'ui\js\survey.js') -Raw -Encoding UTF8
$surveyData = Get-Content (Join-Path $root 'ui\js\survey-data.js') -Raw -Encoding UTF8
if ($idx -notmatch '<section class="page" data-page="survey"') { Bad 'index.html 缺少问卷调查页面' }
if ($idx -notmatch 'data-i18n="nav\.survey"') { Bad 'index.html 侧边栏缺问卷调查项' }
if ($idx -notmatch 'css/survey\.css') { Bad 'index.html 未加载 survey.css' }
$iSurveyData = $idx.IndexOf('js/survey-data.js')
$iSurveyJs = $idx.IndexOf('js/survey.js')
if ($iSurveyData -lt 0 -or $iSurveyJs -lt 0) { Bad 'index.html 未加载 survey-data.js / survey.js' }
elseif ($iSurveyData -gt $iSurveyJs) { Bad 'survey-data.js 必须在 survey.js 之前加载' }
# 侧边栏顺序：性能采集 → 实时监控 → 更新公告 → 问卷调查 → 设置
$navOrder = [regex]::Matches($navBlock, 'data-page="([a-z]+)"') | ForEach-Object { $_.Groups[1].Value }
if (($navOrder -join ',') -ne 'capture,realtime,updates,survey,settings') { Bad "侧边栏顺序不对：$($navOrder -join ' → ')" }
else { Ok "侧边栏顺序：问卷调查在更新公告下面" }
# 无问卷必须显示「暂无问卷」：数据初始为空数组，渲染层给空状态
if ($surveyData -notmatch 'window\.PerfSurveys = \[\]') { Bad 'survey-data.js 初始应为空数组（无问卷时显示暂无问卷）' }
foreach ($need in 'surveyList', 'surveyCount', '__refreshSurvey', 'survey-card', 'survey-empty', 'survey-status', 'survey-actions') {
    if ($surveyJs -notmatch [regex]::Escape($need)) { Bad "survey.js 缺 $need" }
}
foreach ($key in 'emptyTitle', 'emptyHint', 'status.open', 'status.closed', 'metaQuestions', 'metaMinutes', 'count', 'notReady') {
    if ($surveyJs -notmatch [regex]::Escape('survey.' + $key)) { Bad "survey.js 没用到 i18n 的 survey.$key" }
}
if ($surveyJs -notmatch 'go\.disabled = true') { Bad '没有链接的问卷按钮没有置灰（应显示暂未开放）' }
if ($i18nText -notmatch '__refreshSurvey') { Bad 'i18n.js 语言切换后没有重画问卷页' }
foreach ($sk in 'nav.survey', 'survey.title', 'survey.lead', 'survey.count', 'survey.emptyTitle', 'survey.emptyHint', 'survey.status.open', 'survey.status.closed', 'survey.metaQuestions', 'survey.metaMinutes', 'survey.open', 'survey.notReady') {
    $n = ([regex]::Matches($i18nText, [regex]::Escape("'" + $sk + "':"))).Count
    if ($n -lt 3) { Bad "i18n 中 $sk 只有 $n 种语言（需 3）" }
}

# ---------- 5m. 检查更新（多源 + 验签 + 本地校验） ----------
$updPs = Get-Content (Join-Path $root 'src\app\70-Updates.ps1') -Raw -Encoding UTF8
foreach ($need in 'Start-UpdateCheck', 'Start-UpdateAutoCheck', 'Complete-UpdateCheck',
    'Start-UpdateDownload', 'Complete-UpdateDownload', 'Test-UpdateSignature', 'Compare-AppVersion',
    'Test-UpdateHost', 'UpdateManifestSources', 'UpdatePublicKeyXml', 'UpdateAutoCheckDone') {
    if ($updPs -notmatch [regex]::Escape($need)) { Bad "70-Updates.ps1 缺 $need" }
}
if ($updPs -notmatch 'cdn\.jsdelivr\.net') { Bad '清单主源不是 jsDelivr' }
if ($updPs -notmatch 'raw\.githubusercontent\.com') { Bad '清单缺 raw.githubusercontent 备用源' }
if ($updPs -notmatch 'api\.github\.com') { Bad '清单缺 api.github.com 第三源' }
if ($updPs -notmatch 'RSAKeyValue') { Bad '没有内置验签公钥' }
if ($updPs -match 'PRIVATE KEY|private-key|PRIVATEKEY') { Bad '70-Updates.ps1 里疑似写了私钥' }
if ($updPs -notmatch "UpdateAutoCheckDelayMs = 12000") { Bad '自动检查不是启动后 12 秒' }
# 1.4.1 加固契约：逐源验签回退 + 重定向复核 + 边下边算哈希 + 取消 + 停滞看门狗 + 路径限制
if ($updPs -notmatch 'sigFail') { Bad '取清单脚本缺逐源验签标记 sigFail（镜像错配时无法换源）' }
if ($updPs -notmatch 'Test-Sig') { Bad '取清单脚本没有内联验签（无法逐源回退）' }
if ($updPs -notmatch 'RequestMessage\.RequestUri') { Bad '没有按最终地址复核白名单（重定向可绕过）' }
if ($updPs -notmatch 'TransformBlock') { Bad '下载没有边下边算 SHA-256' }
if ($updPs -notmatch 'CancellationTokenSource') { Bad '下载不支持取消（无法中断）' }
if ($updPs -notmatch 'TotalSeconds -gt 60') { Bad '没有下载停滞看门狗' }
if (-not $updPs.Contains('StartsWith($root')) { Bad '运行安装包没有限制在下载目录内' }
if ($updPs -notmatch 'UpdateDelayTimer') { Bad '自动检查的延时计时器没有纳入管理（可能重复检查）' }
if ($capPs -notmatch "'checkUpdate'") { Bad '60-Capture.ps1 没登记 checkUpdate 命令' }
if ($capPs -notmatch 'Start-UpdateAutoCheck') { Bad '60-Capture.ps1 就绪后没有触发自动检查' }
if ($idx -notmatch 'id="btnCheckUpdate"') { Bad 'index.html 缺「检查更新」按钮' }
if ($idx -notmatch 'id="updateBanner"') { Bad 'index.html 缺更新提示条' }
if ($idx -notmatch 'js/update\.js') { Bad 'index.html 未加载 update.js' }
$updJs = Get-Content (Join-Path $root 'ui\js\update.js') -Raw -Encoding UTF8
foreach ($need in 'window.PerfUpdate', 'downloadUpdate', 'runUpdateInstaller', 'skipUpdateVersion', 'setUpdateAuto') {
    if ($updJs -notmatch [regex]::Escape($need)) { Bad "update.js 缺 $need" }
}
if (-not (Test-Path (Join-Path $root 'build\sign-manifest.ps1'))) { Bad '缺 build\sign-manifest.ps1（签名/验签）' }
# 清单（由 pack.ps1 step 9 生成）：存在就校验 schema / 哈希 / 白名单 / 签名
$manPath = Join-Path $root 'updates\latest.json'
if (Test-Path $manPath) {
    $man = $null
    try { $man = (Get-Content $manPath -Raw -Encoding UTF8) | ConvertFrom-Json } catch { }
    if (-not $man) { Bad 'updates\latest.json 不是合法 JSON' }
    else {
        if ($man.version -ne $verFile) { Bad "清单版本 $($man.version) 与 VERSION $verFile 不一致" }
        if (-not $man.serial) { Bad '清单缺 serial（防重放）' }
        if (-not $man.assets -or @($man.assets).Count -lt 1) { Bad '清单没有 assets' }
        else {
            foreach ($a in @($man.assets)) {
                if (-not $a.sha256 -or ([string]$a.sha256).Length -ne 64) { Bad "资产 $($a.name) 的 sha256 不合法" }
                if (-not $a.size) { Bad "资产 $($a.name) 缺 size" }
                foreach ($u in @($a.urls)) {
                    if ($u -notmatch '^https://') { Bad "资产 URL 不是 https：$u" }
                    if ($u -notmatch 'jsdelivr|raw\.githubusercontent|ghproxy|github\.com') { Bad "资产 URL 主机不在白名单：$u" }
                }
                # jsDelivr 拒发 .exe（403）：安装包清单里不该出现这个死链
                if ($a.name -match '\.exe$' -and ($a.urls -join ' ') -match 'jsdelivr') { Bad "资产 $($a.name) 的网址含 jsDelivr（它 403 拒发 exe）" }
                if ($a.name -match '\.exe$' -and ($a.urls[0] -notmatch '^https://raw\.githubusercontent\.com/')) { Bad "资产 $($a.name) 首选源不是 raw（exe 会被 jsDelivr 403）" }
            }
        }
        $sigPath = $manPath + '.sig'
        if (-not (Test-Path $sigPath)) { Bad 'updates\latest.json 缺 .sig（未签名会被客户端拒绝）' }
        elseif (Test-Path (Join-Path $root 'build\sign-manifest.ps1')) {
            $vr = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build\sign-manifest.ps1') -Path $manPath -Verify 2>&1
            if ($LASTEXITCODE -ne 0) { Bad "清单验签失败：$($vr -join ' ')" } else { Ok '更新清单验签通过' }
        }
    }
} else {
    Warn '尚未生成 updates\latest.json（先跑 build\pack.ps1）'
}
# ---------- 5n. 实时监控（批次 A） ----------
$metPs = Get-Content (Join-Path $root 'src\app\35-Metrics.ps1') -Raw -Encoding UTF8
foreach ($need in 'Get-MetricsCapabilities', 'Start-MetricsSampler', 'Stop-MetricsSampler', 'Invoke-MetricsTick', 'MetricsSampleScript', 'Update-MetricsCapsFromSample') {
    if ($metPs -notmatch [regex]::Escape($need)) { Bad "35-Metrics.ps1 缺 $need" }
}
if ($metPs -notmatch 'MetricsIntervalMs = 1000') { Bad '实时监控采样间隔不是 1 秒' }
if ($metPs -notmatch 'MetricsRingSize = 120') { Bad '实时监控环形缓冲不是 120 点' }
if ($metPs -notmatch 'cpuTemp = \$false') { Bad 'CPU 温度占位没有关掉（本版不该提供）' }
if ($metPs -notmatch 'GetSystemTimes|GlobalMemoryStatusEx|CallNtPowerInformation') { Bad '缺少 Win32 只读采集（P/Invoke）' }
# 零注入 / 无驱动：不许出现任何注入或传感器驱动依赖
foreach ($forbidden in 'RTSS', 'RivaTuner', 'OpenHardwareMonitor', 'LibreHardwareMonitor', 'inpainted', 'SetWindowsHookEx', 'WriteProcessMemory') {
    if ($metPs -match [regex]::Escape($forbidden)) { Bad "35-Metrics.ps1 里出现了不该有的依赖：$forbidden" }
}
# 内嵌采样脚本要能单独解析
$ms = [regex]::Match($metPs, "(?s)\`$script:MetricsSampleScript = @'\r?\n(.*?)\r?\n'@")
if (-not $ms.Success) { Bad '取不到内嵌采样脚本' }
else {
    $pe = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($ms.Groups[1].Value, [ref]$null, [ref]$pe)
    if ($pe.Count) { Bad ("内嵌采样脚本语法错误：" + $pe[0].Message) }
}
if ($metPs -notmatch 'type = ''metricSample''') { Bad '没有向界面推送 metricSample' }
if ($metPs -notmatch 'type = ''metricsCaps''') { Bad '没有向界面推送 metricsCaps' }

$rtJs = Get-Content (Join-Path $root 'ui\js\realtime.js') -Raw -Encoding UTF8
foreach ($need in 'window.PerfRealtime', '__refreshRealtime', 'metricsStart', 'metricsStop', 'is-na', 'FIELDS') {
    if ($rtJs -notmatch [regex]::Escape($need)) { Bad "realtime.js 缺 $need" }
}
if ($idx -notmatch 'id="rtCpuRows"') { Bad 'index.html 缺 CPU 行容器 rtCpuRows' }
if ($idx -notmatch 'id="rtGpuRows"') { Bad 'index.html 缺 GPU 行容器 rtGpuRows' }
if ($idx -notmatch 'id="rtToggle"') { Bad 'index.html 缺暂停按钮' }
if ($idx -notmatch 'css/realtime\.css') { Bad 'index.html 没有引入 realtime.css' }
if ($idx -notmatch 'js/realtime\.js') { Bad 'index.html 没有引入 realtime.js' }
if ($brJs -notmatch "case 'metricSample'") { Bad 'bridge.js 没有分发 metricSample' }
foreach ($key in 'realtime.row.util', 'realtime.row.clock', 'realtime.naSensor', 'realtime.stateOn') {
    if ($i18nText -notmatch [regex]::Escape("'" + $key + "'")) { Bad "i18n 缺 $key" }
}
if ($capPs -notmatch "'metricsStart'") { Bad '60-Capture.ps1 没登记 metricsStart 命令' }
$iDispatch = $capPs.IndexOf('Invoke-MetricsCommand $msg')
$iSwitch = $capPs.IndexOf('switch ($msg.cmd) {')
if ($iDispatch -lt 0 -or $iSwitch -lt 0 -or $iDispatch -gt $iSwitch) { Bad '监控命令必须在 switch 之前分发（否则走不到）' }
if ((Get-Content (Join-Path $root 'src\PerfCapture.ps1') -Raw -Encoding UTF8) -notmatch "'35-Metrics.ps1'") { Bad '入口没有加载 35-Metrics.ps1' }


# ---------- 6. 运行时依赖 ----------
Write-Host "`n[6/6] 运行时依赖"
$pm = Join-Path $root 'tools\presentmon.exe'
if (Test-Path $pm) { Ok "内置 PresentMon（$([math]::Round((Get-Item $pm).Length/1KB)) KB）" } else { Bad '缺少 tools\presentmon.exe' }

$builtinWv = Test-Path (Join-Path $root 'runtime\webview2\msedgewebview2.exe')
$builtinEdge = Test-Path (Join-Path $root 'runtime\webview2\msedge.dll')
if ($builtinWv -and $builtinEdge) { Ok '内置 WebView2 运行时可用（完全离线）' }
elseif ($builtinWv -and -not $builtinEdge) { Bad 'runtime\webview2 缺 msedge.dll（NuGet 增量包），会导致启动失败' }
else { Warn '未内置 WebView2 运行时，将使用系统自带的（Win11 必然可用）' }

$smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
if (Test-Path $smi) { Ok 'nvidia-smi 存在（GPU 指标可用）' } else { Warn 'nvidia-smi 缺失：GPU 温度/占用/显存将为 —（不影响帧率）' }

# ---------- 结果 ----------
Write-Host ''
if ($fail -eq 0) {
    Write-Host '== 冒烟测试通过 ==' -ForegroundColor Green
    exit 0
} else {
    Write-Host "== 冒烟测试失败：$fail 项 ==" -ForegroundColor Red
    exit 1
}
