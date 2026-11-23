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
    'src\app\15-Logging.ps1', 'src\app\20-Settings.ps1', 'src\app\30-Tools.ps1',
    'src\app\platform-rules.ps1', 'src\app\vendor-sensor.ps1', 'src\app\cpu-throttle.ps1',
    'src\app\35-Metrics.ps1', 'src\app\55-Overlay.ps1',
    'src\app\40-Bridge.ps1', 'src\app\50-Host.ps1', 'src\app\60-Capture.ps1', 'src\app\68-UpdateWrapper.ps1', 'src\app\rtss-shm.ps1', 'src\app\80-Extensions.ps1', 'src\app\85-ExtensionProvision.ps1', 'src\app\90-Main.ps1',
    'src\engine\Measure-GamePerf.ps1',
    'ui\index.html',
    'ui\css\tokens.css', 'ui\css\layout.css', 'ui\css\components.css',
    'ui\css\terminal.css', 'ui\css\report.css', 'ui\css\popup.css', 'ui\css\updates.css', 'ui\css\survey.css', 'ui\css\extensions.css', 'ui\css\realtime.css',
    'ui\js\util.js', 'ui\js\i18n.js', 'ui\js\capture-options.js', 'ui\js\bridge.js',
    'ui\js\theme.js', 'ui\js\popup.js', 'ui\js\terminal.js', 'ui\js\ui-state.js',
    'ui\js\report.js', 'ui\js\collapse.js', 'ui\js\split.js',
    'ui\js\sidebar.js', 'ui\js\settings.js', 'ui\js\main.js',
    'ui\js\updates-data.js', 'ui\js\updates.js', 'ui\js\survey-data.js', 'ui\js\survey.js', 'ui\js\extensions-data.js', 'ui\js\extensions.js', 'ui\js\realtime.js',
    'assets\app-icon.ico', 'assets\app-icon.png',
    'lib\Microsoft.Web.WebView2.Core.dll', 'lib\Microsoft.Web.WebView2.WinForms.dll', 'lib\WebView2Loader.dll',
    'tools\presentmon.exe',
    'deps\deps.json', 'deps-inbox\说明.txt', 'capture-options.json', 'capture-metrics.json', 'extensions.json'
)
foreach ($p in $structure) {
    if (-not (Test-Path (Join-Path $root $p))) { Bad "缺少 $p" }
}
# build\ 只在开发目录存在，分发包里没有，不做必检。
# 判定认构建输入 launcher.cs：发布产物的 build\ 只放验签脚本，不能算"开发目录"。
$isDevTree = Test-Path (Join-Path $root 'build\launcher.cs')
if ($isDevTree -and -not (Test-Path (Join-Path $root 'build\pack.ps1'))) {
    Bad '缺少 build\pack.ps1'
}
# dist 只保留最近 3 个发布版本：清理脚本必须存在，且 pack.ps1 必须真的调用它
if ($isDevTree) {
    if (-not (Test-Path (Join-Path $root 'build\prune-dist.ps1'))) { Bad '缺少 build\prune-dist.ps1（dist 保留规则）' }
    $packSrc = Get-Content (Join-Path $root 'build\pack.ps1') -Raw -Encoding UTF8
    if ($packSrc -notmatch 'prune-dist\.ps1') { Bad 'pack.ps1 没有调用 prune-dist.ps1（dist 会无限增长）' }
    if ($packSrc -notmatch 'KeepDistVersions\s*=\s*3') { Bad 'pack.ps1 的 KeepDistVersions 默认值不是 3' }
    if ($packSrc -notmatch "PerfCapture-Update-") { Bad 'pack.ps1 没有生成 jsDelivr 回退包' }
    if ($packSrc -notmatch 'innerSha256') { Bad '回退包清单没有记录内层 exe 哈希' }
    $pushSrc = Get-Content (Join-Path $root 'build\push-updates.ps1') -Raw -Encoding UTF8
    if ($pushSrc -notmatch 'PerfCapture-Update-') { Bad 'push-updates.ps1 没有同步回退包' }
    if ($pushSrc -notmatch '\(\?:-Setup\|-Update\)\?') { Bad 'push-updates.ps1 清理旧版本时漏掉回退包' }
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
        $nAlways = 0
        foreach ($o in $opts) {
            if (-not $o.skip -or -not $o.label) { Bad '采集项缺少 skip 或 label'; $bad++; continue }
            $n = ([regex]::Matches($i18nText, [regex]::Escape("'" + $o.label + "':"))).Count
            if ($n -lt 3) { Bad ("i18n 中 $($o.label) 只有 $n 种语言（需 3）"); $bad++ }
            $hasBranch = ($engText -match ('-contains ''' + [regex]::Escape($o.skip) + ''''))
            # kind：core（无条件采集）/ optional（可开关）/ derived（算出来的）。旧清单只有 always
            $kind = if ($o.kind) { [string]$o.kind } elseif ($o.always) { 'core' } else { 'optional' }
            if (@('core', 'optional', 'derived') -notcontains $kind) { Bad "采集项 $($o.skip) 的 kind=$kind 非法"; $bad++; $kind = 'optional' }
            if ($kind -eq 'core') { $nAlways++ }
            if ($kind -eq 'optional') {
                # 可选开关必须真的有引擎分支，否则那个可勾可取消的框就是假的
                if (-not $hasBranch) { Bad ("引擎没有 skip=$($o.skip) 的采集分支"); $bad++ }
            } else {
                # 核心项与派生项：引擎里必须**没有**对应 skip 分支，否则界面上「关不掉」就是假的
                if ($hasBranch) { Bad ("$($o.skip) 是 $kind，但引擎仍有 skip 分支"); $bad++ }
            }
        }
        if ($bad -eq 0) { Ok "采集项清单一致（$($opts.Count) 项 · 文案三语齐全 · 可选 $($opts.Count - $nAlways - @($opts | Where-Object { $_.kind -eq 'derived' }).Count) 项引擎分支齐全 · 始终采集 $nAlways 项 · 派生 $(@($opts | Where-Object { $_.kind -eq 'derived' }).Count) 项）" }
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
# B1（2.0.1）起 1% Low 统一口径：**不再丢最差那一帧**，直接用全部帧算；
# 同时必须有 0.1% Low、卡顿合并统计、GPU Busy 与逐帧列解析。
if ($engPs -match 'Select-Object -Skip 1') { Bad '引擎仍在丢弃最差帧（1% Low 口径应已统一）' }
foreach ($need in @('fps_01pct_low', 'Get-LowFps', 'stutterSegments', 'gpu_busy_pct', 'cpu_frame_ms', 'gpu_render_ms', "'CPUBusy'", "'GPUBusy'")) {
    if ($engPs -notmatch [regex]::Escape($need)) { Bad "引擎缺 B1 数据层要素：$need" }
}
if ($i18nText -notmatch 'metric\.lowPerSec') { Bad 'i18n 缺「逐秒最低帧率」词条（口径已改名）' }
if ($engPs -notmatch 'lowHitsPct') { Bad '引擎缺落回频率统计（lowHitsPct）' }
foreach ($jk in 'fps_1pct_low_pct', 'low_hits_pct') {
    if ($engPs -notmatch $jk) { Bad "JSON 契约缺 $jk" }
}
# 2.0.6：旧的「落回 1% Low 附近」判定已从引擎移除（评审 §3），改断言新的两句事实陈述
foreach ($vk in 'verdict.low.ratio', 'verdict.ft.maxframe') {
    if ($engPs -notmatch [regex]::Escape("'" + $vk + "'")) { Bad "引擎未发出 $vk" }
    $n = ([regex]::Matches($i18nText, [regex]::Escape("'" + $vk + "':"))).Count
    if ($n -lt 3) { Bad "i18n 中 $vk 只有 $n 种语言（需 3）" }
}
foreach ($vk in 'verdict.low.smooth', 'verdict.low.occasional', 'verdict.low.frequent') {
    if ($engPs -match [regex]::Escape("'" + $vk + "'")) { Bad "引擎仍在使用旧的 $vk（会误导用户）" }
}
# 曲线纵轴必须容得下最慢一帧，不能出现「0.1% Low 很低但曲线看着平」
if ($engPs -notmatch 'frametime_max_ms') { Bad '引擎缺 frametime_max_ms（纵轴/卡顿说明要用）' }
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

# ---------- 5g-2. 2.1.9 报告元数据：帧数据源单一口径 ----------
if ($engPs -notmatch '\$FpsSource = ''presentmon''') { Bad '引擎缺 FpsSource 参数（报告无法标注帧数据源）' }
if ($engPs -notmatch 'fps_source = \$FpsSource') { Bad '引擎报告 environment 缺 fps_source 字段' }
if ($engPs -notmatch '-FpsSource') { Bad '引擎自我提权时没有透传 FpsSource' }
$capturePs = Get-Content (Join-Path $root 'src\app\60-Capture.ps1') -Raw -Encoding UTF8
if ($capturePs -notmatch '\$fpsSource = if \(\$script:ActiveFpsSource\)') { Bad '宿主没有把当前数据源传给采集引擎' }
if ($capturePs -notmatch '-FpsSource \$fpsSource') { Bad '宿主启动引擎时未传 -FpsSource' }
$metricsDoc = Get-Content (Join-Path $root 'capture-metrics.json') -Raw -Encoding UTF8
if ($metricsDoc -notmatch '"env\.fpsSource"') { Bad 'capture-metrics.json 缺 env.fpsSource 行' }
if ($repJs -notmatch "'env\.fpsSource':") { Bad 'report.js 缺 env.fpsSource 渲染映射' }
foreach ($key in 'metric.fpsSource', 'value.fpsPresentmon', 'value.fpsExtension') {
    $n = ([regex]::Matches($i18nText, [regex]::Escape("'" + $key + "':"))).Count
    if ($n -ne 3) { Bad "i18n 中 $key 只有 $n 种语言（需 3）" }
}

# ---------- 5h. 更新公告 / 实时监控入口 ----------
$dataJs = Get-Content (Join-Path $root 'ui\js\updates-data.js') -Raw -Encoding UTF8
$updJs = Get-Content (Join-Path $root 'ui\js\updates.js') -Raw -Encoding UTF8
$verFile = (Get-Content (Join-Path $root 'VERSION') -Raw -Encoding UTF8).Trim()
# 侧边栏：功能区（采集 / 实时监控）+ 底部组（更新公告 / 设置）+ 版本号
$navBlock = [regex]::Match($idx, '(?s)<nav class="sidebar-nav">.*?</nav>').Value
$navPages = [regex]::Matches($navBlock, 'data-page="([a-z]+)"') | ForEach-Object { $_.Groups[1].Value }
if ($navPages.Count -lt 4) { Bad "侧边栏只有 $($navPages.Count) 项（应有采集 / 实时监控 / 更新公告 / 设置）" }
elseif ($navPages[1] -ne 'reports' -or $navPages[2] -ne 'realtime') { Bad "侧边栏顺序不对：$($navPages -join ' → ')" }

# 版本清单一致性：2.1.x 每个 CHANGELOG 版本都必须有更新公告条目，反之亦然。
# 2.1.0 之前是「版本号重编号」前的历史段落（1.6–1.9 / 1.0），公告里本来就不收，不参与比对。
# 这条守卫的由来：2.1.13 曾只写进 CHANGELOG、公告里被合并掉，用户看着就是「少了一版」。
$chgAll = Get-Content (Join-Path $root 'CHANGELOG.md') -Raw -Encoding UTF8
$chgVers = @([regex]::Matches($chgAll, '(?m)^## ([0-9]+\.[0-9]+\.[0-9]+)') |
    ForEach-Object { $_.Groups[1].Value } | Where-Object { [version]$_ -ge [version]'2.1.0' })
$annVers = @([regex]::Matches($dataJs, "version:\s*'([0-9]+\.[0-9]+\.[0-9]+)'") |
    ForEach-Object { $_.Groups[1].Value } | Where-Object { [version]$_ -ge [version]'2.1.0' })
$missAnn = @($chgVers | Where-Object { $annVers -notcontains $_ })
$missChg = @($annVers | Where-Object { $chgVers -notcontains $_ })
if ($missAnn.Count) { Bad ("更新公告缺版本：" + ($missAnn -join ', ')) }
if ($missChg.Count) { Bad ("CHANGELOG 缺版本：" + ($missChg -join ', ')) }
if (-not $missAnn.Count -and -not $missChg.Count) {
    Ok ("版本清单一致：2.1.x 共 $($chgVers.Count) 个版本，公告与 CHANGELOG 对得上")
}
if ($navPages -notcontains 'extensions') { Bad '侧边栏缺扩展中心入口（应在 survey 与 settings 之间）' }
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
# 版本线（主.次）只在 PerfUpdateVersions 数组里校验；条目号（主.次.补丁）在 PerfUpdates 里。
# 两类号码必须分开排序 —— 混在一起会把「2.0.27 之后接 2.1 版本线」误判成乱序。
$vlBlock = [regex]::Match($dataJs, '(?s)window\.PerfUpdateVersions\s*=\s*\[.*?\];').Value
$verList = [regex]::Matches($vlBlock, "version:\s*'([0-9]+\.[0-9]+)'") | ForEach-Object { $_.Groups[1].Value }
if ($verList.Count -lt 4) { Bad "版本记录至少应有四条（1.1 起），实际 $($verList.Count) 条" }
elseif (($verList -join ',') -ne (($verList | Sort-Object -Descending { [version]($_ + '.0') }) -join ',')) {
    Bad "版本记录顺序不对（应新→旧）：$($verList -join ' , ')"
}
if ($verList -notcontains '1.5' -and $verFile -match '^1\.5\.') { Bad '1.5 版本线缺失（当前版本是 1.5.x）' }
if ($dataJs -notmatch "version: '1\.4', date: '2026-11-16'") { Bad '1.4 版本线的发布日期不是 2026-11-16' }
if ($dataJs -notmatch "version: '1\.3', date: '2026-11-15'") { Bad '1.3 版本线的发布日期不是 2026-11-15' }
if ($dataJs -notmatch [regex]::Escape("version: '$verFile'")) { Bad "updates-data.js 里没有当前版本 $verFile 的条目" }
$upBlock = [regex]::Match($dataJs, '(?s)window\.PerfUpdates\s*=\s*\[.*?\n\];').Value
$entryVers = [regex]::Matches($upBlock, "version: '(\d+\.\d+)\.\d+'") | ForEach-Object { $_.Groups[1].Value }
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
# 「开发目录」判定复用前面的 $isDevTree（认 launcher.cs，不认 build 目录本身），
# 发布产物的 build\ 只放验签脚本，不能因此触发仓库交付类断言。
$hasBuild = $isDevTree
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
# 侧边栏顺序：性能采集 → 历史报告 → 实时监控 → 更新公告 → 问卷调查 → 扩展中心 → 设置
$navOrder = [regex]::Matches($navBlock, 'data-page="([a-z]+)"') | ForEach-Object { $_.Groups[1].Value }
if (($navOrder -join ',') -ne 'capture,reports,realtime,updates,survey,extensions,settings') { Bad "侧边栏顺序不对：$($navOrder -join ' → ')" }
else { Ok "侧边栏顺序：历史报告紧跟采集，扩展中心在问卷调查与设置之间" }
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

# ---------- 5l. 扩展中心页（批次 B：UI 骨架 + 状态展示，不接宿主） ----------
$extJs = Get-Content (Join-Path $root 'ui\js\extensions.js') -Raw -Encoding UTF8
$extData = Get-Content (Join-Path $root 'ui\js\extensions-data.js') -Raw -Encoding UTF8
if ($idx -notmatch '<section class="page" data-page="extensions"') { Bad 'index.html 缺少扩展中心页面' }
if ($idx -notmatch 'data-i18n="nav\.extensions"') { Bad 'index.html 侧边栏缺扩展中心项' }
if ($idx -notmatch 'css/extensions\.css') { Bad 'index.html 未加载 extensions.css' }
$iExtData = $idx.IndexOf('js/extensions-data.js')
$iExtJs = $idx.IndexOf('js/extensions.js')
if ($iExtData -lt 0 -or $iExtJs -lt 0) { Bad 'index.html 未加载 extensions-data.js / extensions.js' }
elseif ($iExtData -gt $iExtJs) { Bad 'extensions-data.js 必须在 extensions.js 之前加载' }
# WebView2 UDF 持久缓存：同 URL 的旧 HTML/JS 会让扩展中心停在批次 B 的「暂无扩展」。
# 扩展相关资源必须带缓存版本查询串，宿主导航 URL 也必须带同一版本。
foreach ($asset in 'css/extensions.css', 'js/i18n.js', 'js/bridge.js', 'js/extensions-data.js', 'js/extensions.js') {
    if ($idx -notmatch ([regex]::Escape($asset) + '\?v=' + [regex]::Escape($verFile))) {
        Bad "扩展中心资源 $asset 缺 ?v=$verFile（WebView2 会读到旧缓存）"
    }
}
$hostText = Get-Content (Join-Path $root 'src\app\50-Host.ps1') -Raw -Encoding UTF8
if ($hostText -notmatch ("UiCacheKey = '" + [regex]::Escape($verFile) + "'")) { Bad "50-Host.ps1 的 UI 缓存版本不是 $verFile" }
if ($hostText -notmatch "ui/index\.html\?v=' \+") { Bad '50-Host.ps1 导航 URL 未带缓存版本查询串' }
foreach ($need in 'extensionsList', 'extensionsCount', 'extAreas', 'extFilters', 'extOnlyInstalled', 'extRefresh', 'extRiskBanner', '__refreshExtensions', 'ext-card', 'ext-status', 'extensions-empty') {
    if ($extJs -notmatch [regex]::Escape($need) -and $idx -notmatch [regex]::Escape($need)) { Bad "扩展中心缺 $need" }
}
if ($extData -notmatch 'window\.PerfExtensions') { Bad 'extensions-data.js 缺 window.PerfExtensions' }
# 状态展示必须覆盖状态模型的各态；本批次全部 planned（不做假开关）
foreach ($st in 'planned', 'notInstalled', 'installed', 'enabled', 'unsupported', 'failed') {
    if ($extJs -notmatch [regex]::Escape($st)) { Bad "extensions.js 缺状态 $st" }
}
if ($extJs -notmatch 'PerfExtensionsUI') { Bad 'extensions.js 未暴露 PerfExtensionsUI（批次 C 宿主消息入口）' }
if ($i18nText -notmatch '__refreshExtensions') { Bad 'i18n.js 语言切换后没有重画扩展中心页' }
foreach ($sk in 'nav.extensions', 'extensions.title', 'extensions.lead', 'extensions.risk', 'extensions.count',
              'extensions.install', 'extensions.notReady', 'extensions.emptyTitle', 'extensions.emptyHint',
              'extensions.status.planned', 'extensions.field.metrics', 'extensions.cat.all') {
    $n = ([regex]::Matches($i18nText, [regex]::Escape("'" + $sk + "':"))).Count
    if ($n -lt 3) { Bad "i18n 中 $sk 只有 $n 种语言（需 3）" }
}
Ok '扩展中心：页面 / 资源顺序 / 状态模型 / 宿主消息入口 / 三语文案齐全'

# ---------- 5l-C. 扩展中心宿主侧（批次 C：注册表 + 状态机 + 真关闭 + 桥接） ----------
$extHostPs = Get-Content (Join-Path $root 'src\app\80-Extensions.ps1') -Raw -Encoding UTF8
$entryPs   = Get-Content (Join-Path $root 'src\PerfCapture.ps1') -Raw -Encoding UTF8
$setPs     = Get-Content (Join-Path $root 'src\app\20-Settings.ps1') -Raw -Encoding UTF8
# 数组契约：Get-ExtensionStates 不能 return ,$array，否则调用方 @() 会二次包装成 JSON 嵌套数组
if ($extHostPs -match '(?m)^\s*return ,\s*\$out\.ToArray\(\)\s*$') { Bad 'Get-ExtensionStates 仍用 return ,$array（会让 extensions 变成嵌套数组）' }
$regJson   = Get-Content (Join-Path $root 'extensions.json') -Raw -Encoding UTF8
$reg       = $regJson | ConvertFrom-Json
# 注册表：结构与「如实发布」（批次 D 起 RTSS 为首个 available=true 的真实扩展）
if (@($reg.extensions).Count -lt 1) { Bad 'extensions.json 没有任何扩展条目' }
$published = @($reg.extensions | Where-Object { $_.available -eq $true })
# v2.1.10：可发布的条目 = 1 个可安装扩展（rtss-shm）+ 1 个内置能力（cpu-sensor）。
# 内置能力没有 package、不参与供应层/看护；可安装扩展仍然只能有 rtss-shm 一个。
$pubReal = @($published | Where-Object { -not $_.builtin })
if ($pubReal.Count -ne 1 -or $pubReal[0].id -ne 'rtss-shm') {
    Bad "available=true 的可安装扩展应恰为 rtss-shm（批次 D），实际：$($pubReal.id -join ',')"
}
if ($pubReal.Count -eq 1 -and ($pubReal[0].mode -ne 'external-shm' -or -not $pubReal[0].shmName)) {
    Bad 'RTSS 应为 external-shm 模式且声明 shmName（不捆绑 payload）'
}
$cpuReg = @($published | Where-Object { $_.id -eq 'cpu-sensor' })
if ($cpuReg.Count -ne 1) { Bad 'cpu-sensor 未以 available=true 发布（v2.1.10 起为内置能力）' }
else {
    if (-not $cpuReg[0].builtin) { Bad 'cpu-sensor 必须标记 builtin=true（随主程序提供，不安装）' }
    if ($cpuReg[0].package) { Bad 'cpu-sensor 不应有 package（不捆绑任何组件）' }
    if ($cpuReg[0].mode -ne 'builtin-vendor') { Bad 'cpu-sensor 模式应为 builtin-vendor' }
}
foreach ($f in 'id', 'name', 'category', 'available', 'detect', 'payload') {
    if ($null -eq $reg.extensions[0].$f) { Bad "扩展注册表首条缺字段 $f" }
}
# 宿主模块：状态机 + 细分失败 + 真关闭四步 + 白名单六命令
foreach ($need in 'Get-ExtensionRegistry', 'Get-ExtensionStates', 'Get-ExtensionStateFor',
                  'Test-ExtensionDependency', 'Invoke-ExtensionCommand', 'Set-FpsSource',
                  'Install-ExtensionCore', 'Enable-ExtensionCore', 'Disable-ExtensionCore', 'Uninstall-ExtensionCore',
                  'Stop-ExtensionProcess', 'Stop-AllExtensionProcesses', 'Send-ExtensionError') {
    if ($extHostPs -notmatch [regex]::Escape($need)) { Bad "80-Extensions.ps1 缺函数 $need" }
}
foreach ($st in 'planned', 'notInstalled', 'installed', 'enabled', 'unsupported', 'failed') {
    if ($extHostPs -notmatch [regex]::Escape("'" + $st + "'")) { Bad "宿主状态机缺状态 $st" }
}
# 真关闭必须做到：断 IPC → 终止进程 → 数据源回退 → 持久化 → 回推
$dis = [regex]::Match($extHostPs, 'function Disable-ExtensionCore[\s\S]*?\r?\n}').Value
foreach ($step in 'ExtIpc.Remove', 'Stop-ExtensionProcess', "Set-FpsSource 'presentmon'", 'Set-ExtensionPersistState', 'Send-ExtensionState') {
    if ($dis -notmatch [regex]::Escape($step)) { Bad "真关闭 Disable-ExtensionCore 缺步骤: $step" }
}
# 命令白名单（2.0.23 metricsTarget 教训：没进白名单的命令会被拒）
foreach ($cmd in 'listExtensions', 'installExtension', 'enableExtension', 'disableExtension', 'uninstallExtension', 'refreshExtensionStatus', 'oneClickEnableExtension') {
    if ($capPs -notmatch [regex]::Escape("'" + $cmd + "'")) { Bad "60-Capture.ps1 白名单缺 $cmd" }
    if ($extHostPs -notmatch [regex]::Escape("'" + $cmd + "'")) { Bad "80-Extensions.ps1 分发缺 $cmd" }
}
if ($entryPs -notmatch '80-Extensions\.ps1') { Bad 'PerfCapture.ps1 未登记 80-Extensions.ps1（dot-source 列表）' }
if ($entryPs -notmatch 'rtss-shm\.ps1') { Bad 'PerfCapture.ps1 未登记 rtss-shm.ps1（dot-source 列表）' }
elseif ($entryPs -notmatch 'rtss-shm\.ps1[\s\S]*80-Extensions\.ps1') { Bad 'rtss-shm.ps1 必须在 80-Extensions.ps1 之前加载（依赖探测要用到读取器）' }
if ($entryPs -notmatch '80-Extensions\.ps1[\s\S]*85-ExtensionProvision\.ps1') { Bad 'PerfCapture.ps1 必须在 80-Extensions.ps1 之后加载 85-ExtensionProvision.ps1' }

# ---------- 5l-E. 批次 E：配置驱动、一键供应、自启与回滚守卫 ----------
$provPs = Get-Content (Join-Path $root 'src\app\85-ExtensionProvision.ps1') -Raw -Encoding UTF8
foreach ($need in 'Start-ExtensionProvision', 'Complete-ExtensionProvision', 'Start-EnabledExtensions',
                 'Invoke-ProvisionRollback', 'hashMismatch', 'shmNotReady', 'ConcurrentQueue',
                 'Start-ProvisionProcess', 'Fail-Stage', 'uacCancelled', 'cacheHit', 'installSuccessCodes') {
    if ($provPs -notmatch [regex]::Escape($need)) { Bad "85-ExtensionProvision.ps1 缺关键实现：$need" }
}
# E1（2.1.2）：空 ArgumentList 曾让真机每次安装都回滚；源码级钉死统一启动器与缓存语义。
if ($provPs -match 'Start-Process -FilePath \$cmd -ArgumentList \$pargs') { Bad '供应层仍在给 Start-Process 传空参数列表' }
if ($provPs -notmatch 'archivePath \+ ''\.part''') { Bad '下载未走 .part 临时文件，半截包可能污染缓存' }
if ($provPs -notmatch "Fail-Stage 'start'") { Bad '启动阶段未走阶段化异常包装' }
if ($extHostPs -notmatch 'detail = \$Detail') { Bad 'Send-ExtensionError 未把 detail 下发前端' }
# 供应层不得硬编码第三方下载信息：URL / 哈希 / 版本只能来自 extensions.json。
foreach ($hard in 'ftp.nluug.nl', '9B084A8CB3E', 'RTSSSetup737') {
    if ($provPs -match [regex]::Escape($hard)) { Bad "85-ExtensionProvision.ps1 硬编码了注册表信息：$hard" }
}
$mainPs = Get-Content (Join-Path $root 'src\app\90-Main.ps1') -Raw -Encoding UTF8
if ($mainPs -notmatch 'Start-EnabledExtensions') { Bad '90-Main.ps1 缺启动自启钩子' }
if ($mainPs -notmatch 'Stop-AllExtensionProcesses') { Bad '90-Main.ps1 缺退出清理钩子' }
# 2.1.9 运行期看护（§10.5）：独立计时器 + 退出前先停，用户关闭有抑制窗
if ($mainPs -notmatch 'Invoke-ExtensionWatchdogTick') { Bad '90-Main.ps1 未接入扩展看护 tick' }
if ($mainPs -notmatch '\$script:ExtWatchTimer\.Stop\(\)') { Bad '退出时未先停看护计时器（杀进程会被误判成崩溃重启）' }
if ($extHostPs -notmatch 'function Invoke-ExtensionWatchdogTick') { Bad '80-Extensions.ps1 缺看护 tick 实现' }
if ($extHostPs -notmatch 'Set-ExtensionWatchSuppressed') { Bad '用户主动关闭没有抑制看护' }
if ($extHostPs -notmatch 'ExtWatchBackoffSec\s*=\s*@\(2,\s*4\)') { Bad '看护退避不是 2/4 秒' }
if ($extHostPs -notmatch 'attempts -ge 2') { Bad '看护重启没有 2 次上限' }
if ($provPs -notmatch 'function Start-ExtensionCopy\(\$Entry, \[int\]\$ReadyWaitMs') { Bad 'Start-ExtensionCopy 不支持看护的短等待参数' }
foreach ($key in 'watchdogRestartFailed', 'watchdogFailed') {
    $n = ([regex]::Matches($i18nText, [regex]::Escape("'extensions.reason." + $key + "':"))).Count
    if ($n -ne 3) { Bad "i18n 缺 extensions.reason.$key（需 3 语，实际 $n）" }
}
$pubPkg = @($published | Where-Object { $_.package -and $_.package.kind -eq 'nsis-zip' })
if ($pubPkg.Count -ne 1) { Bad '已发布扩展只有一个，且必须声明 package（nsis-zip）' }
else {
    $pkg = $pubPkg[0].package
    foreach ($fk in 'version', 'url', 'sha256', 'installerRelative', 'installArgs', 'processCommand', 'verifyTimeoutMs') {
        if (-not $pkg.$fk) { Bad "RTSS package 缺字段：$fk" }
    }
    if ($pkg.sha256 -notmatch '^[0-9A-Fa-f]{64}$') { Bad 'RTSS package.sha256 不是 64 位十六进制' }
    if (-not [bool]$pkg.elevateInstall) { Bad 'RTSS package.elevateInstall 应为 true（用户已接受一次 UAC）' }
    if ([bool]$pkg.allowLocalSource) { Bad '生产 package.allowLocalSource 必须为 false（本地源仅供探针）' }
}
if ($regJson -notmatch '"lifecycle"') { Bad 'extensions.json 缺 lifecycle（自启/自有进程边界）' }
# 读取器：纯 .NET，不硬编码 app 数组位置，口径从帧时间缓冲自算，失败细分
$readerPs = Get-Content (Join-Path $root 'src\app\rtss-shm.ps1') -Raw -Encoding UTF8
foreach ($need in 'MemoryMappedFile', 'dwAppArrOffset', 'RtssReaderSource', 'Get-RtssFrameSnapshot', 'fpsLow1', 'shmNotFound', 'staleData') {
    if ($readerPs -notmatch [regex]::Escape($need)) { Bad "rtss-shm.ps1 缺关键实现：$need" }
}
if ($readerPs -notmatch '1000000\.0 / \$slowAvgUs') { Bad '1% Low 未按项目口径（最慢1%平均帧时间取倒数）计算' }
# 签名是官方 C 多字符常量 'RTSS'（MSVC = 0x52545353）。曾写成内存字节序 0x53535452，
# 结果真机读到正确数据也判 badSignature，用户看到「版本不兼容」。
if ($readerPs -notmatch '0x52545353') { Bad '读取器未按官方多字符常量 0x52545353 校验签名' }
if ($readerPs -notmatch '\$sigAccepted') { Bad '读取器未同时接受兼容签名写法（0x53535452）' }
# HWiNFO 共享内存读取器已于 2026-11-22 移除（HWiNFO 非开源 + 免费版共享内存 12 小时限制）。
# 这里做反向守卫：文件、入口加载、注册表条目、宿主/采样分支都不许悄悄复活。
if (Test-Path (Join-Path $root 'src\app\hwinfo-shm.ps1')) { Bad 'hwinfo-shm.ps1 已移除，不应再出现' }
$entryPs2 = Get-Content (Join-Path $root 'src\PerfCapture.ps1') -Raw -Encoding UTF8
if ($entryPs2 -match 'hwinfo-shm') { Bad '入口仍加载 hwinfo-shm.ps1' }
if ($extHostPs -notmatch 'function Get-ExtensionShmSnapshot') { Bad '宿主缺共享内存读取器分派入口' }
if ($extHostPs -match 'HwinfoFrameSnapshot|HwinfoReaderSource') { Bad '宿主仍残留 HWiNFO 读取器分支' }
if ($metPs -match 'HwinfoReaderCode|HwinfoFrameSnapshot') { Bad '采样侧仍残留 HWiNFO 读取器注入' }
$hwReg = @($published | Where-Object { $_.id -eq 'hwinfo-shm' })
if ($hwReg.Count -ne 0) { Bad '注册表仍发布 hwinfo-shm（已决定移除）' }
# FrameView 与自研 ETW 消费者已于 2026-11-22 按用户决定移除（理由见规则文档 §7）：
# 前者帧率能力与 PresentMon 同源、无精度增益，独有能力（逐帧对齐 GPU 遥测 / PCAT）不在报告口径内，
# 且 SDK 服务占用 ETW 通道、EULA 与开源分发冲突；后者等于把 3–5 天开发 + DxgKrnl schema 漂移的维护成本留在项目里。
foreach ($deadId in 'frameview', 'etw-consumer') {
    if (@($reg.extensions | Where-Object { $_.id -eq $deadId }).Count -ne 0) { Bad "注册表仍保留已否决条目 $deadId" }
    # 只认 id 声明：注释里提到"已删除的条目"是正常的，不能当成复活。
    if ($extData -match ("id:\s*'" + [regex]::Escape($deadId) + "'")) { Bad "扩展中心前端镜像仍保留已否决条目 $deadId" }
}
if (Test-Path (Join-Path $root 'tests\probe-b145-frameview.ps1')) { Bad 'probe-b145-frameview.ps1 已移除，不应再出现' }
foreach ($key in 'versionMismatch', 'noReadings') {
    $n = ([regex]::Matches($i18nText, [regex]::Escape("'extensions.reason." + $key + "':"))).Count
    if ($n -ne 3) { Bad "i18n 缺 extensions.reason.$key（需 3 语，实际 $n）" }
}
# 待机 vs 故障：noEntry/noFrames/staleData 属正常待机，判成 failed 会让数据源永远切不过去。
$idleBlock = [regex]::Match($extHostPs, '\$script:ShmIdleReasons\s*=\s*@\(([^)]*)\)')
if (-not $idleBlock.Success -or $idleBlock.Groups[1].Value -notmatch 'noEntry') { Bad '缺待机口径 ShmIdleReasons（noEntry/noFrames/staleData）' }
$brokenBlock = [regex]::Match($extHostPs, '\$script:ShmBrokenReasons\s*=\s*@\(([\s\S]*?)\)\r?\n')
if (-not $brokenBlock.Success) { Bad '缺故障口径 ShmBrokenReasons' }
elseif ($brokenBlock.Groups[1].Value -match 'noEntry') { Bad 'noEntry 被误列入故障口径（会重现「不是可用数据源」）' }
if ($extHostPs -notmatch 'Test-ExtensionShmBroken \$dep\.shmState') { Bad '状态机未用统一故障口径判断 failed' }
# 供应层运行态校验必须复用同一读取器，并把不兼容单独报出来。
if ($provPs -notmatch 'RtssReaderCode') { Bad '供应层未复用宿主的共享内存读取器（会重复维护结构常量）' }
if ($provPs -notmatch 'shmIncompatible') { Bad '供应层未把结构不兼容单独细分（shmIncompatible）' }
# 已安装副本的复用入口：没有它，每次启动都会重跑安装器并再弹一次 UAC。
if ($provPs -notmatch 'function Start-ExtensionCopy') { Bad '供应层缺复用已安装副本入口（每次启动都会重装）' }
# 采样侧也必须按同一口径区分待机与故障：否则「没开游戏」会触发回退，而回退会真的关掉扩展。
$metricsPs = Get-Content (Join-Path $root 'src\app\35-Metrics.ps1') -Raw -Encoding UTF8
if ($metricsPs -notmatch 'brokenReasons') { Bad '采样侧未区分待机与故障（没开游戏会把扩展自动关掉）' }
$mainPs = Get-Content (Join-Path $root 'src\app\90-Main.ps1') -Raw -Encoding UTF8
if ($mainPs -notmatch 'Stop-AllExtensionProcesses') { Bad '90-Main.ps1 退出时未清理扩展进程（会留孤儿）' }
# 持久化整块遍历（overlay 教训）
if ($setPs -notmatch '\$j\.extensions\.PSObject\.Properties') { Bad '20-Settings.ps1 未按属性整块遍历 extensions（会丢状态）' }
# 桥接：UI 收三种宿主消息 + 三命令回推
foreach ($h in "case 'extensions'", "case 'extensionState'", "case 'extensionError'") {
    if ($brJs -notmatch [regex]::Escape($h)) { Bad "bridge.js 缺宿主消息 $h" }
}
foreach ($api in 'apply(', 'state(', 'error(') {
    if ($extJs -notmatch [regex]::Escape($api)) { Bad "extensions.js 缺宿主入口 $api" }
}
# i18n 三语新键（启用 / 关闭 / 卸载 / 细分失败原因）
foreach ($sk in 'extensions.enable', 'extensions.disable', 'extensions.uninstall',
              'extensions.reason.notAvailable', 'extensions.reason.dependencyMissing',
              'extensions.oneClick', 'extensions.progress', 'extensions.stage.download',
              'extensions.reason.hashMismatch', 'extensions.reason.shmNotReady',
              'extensions.reason.startFailed', 'extensions.reason.downloadFailed',
              'extensions.reason.extractFailed', 'extensions.reason.configureFailed',
              'extensions.reason.verifyRuntimeFailed', 'extensions.reason.uacCancelled',
              'extensions.copyDiagnostics') {
    $n = ([regex]::Matches($i18nText, [regex]::Escape("'" + $sk + "':"))).Count
    if ($n -lt 3) { Bad "i18n 中 $sk 只有 $n 种语言（需 3）" }
}
Ok '扩展中心宿主侧：注册表 / 状态机 / 真关闭四步 / 白名单六命令 / 桥接三消息齐全'

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
# 1.4.1 加固契约：逐源验签回退 + 重定向复核 + 整包哈希 + 取消 + 停滞看门狗 + 路径限制
if ($updPs -notmatch 'sigFail') { Bad '取清单脚本缺逐源验签标记 sigFail（镜像错配时无法换源）' }
if ($updPs -notmatch 'Test-Sig') { Bad '取清单脚本没有内联验签（无法逐源回退）' }
if ($updPs -notmatch 'RequestMessage\.RequestUri') { Bad '没有按最终地址复核白名单（重定向可绕过）' }
# 2.1.8：跨源续传后必须对**整个文件**重算哈希（边下边算在断点续传下无法成立）
if ($updPs -notmatch 'Get-FileHash -LiteralPath \$OutPath') { Bad '下载完成后没有整包复算 SHA-256' }
if ($updPs -notmatch 'CancellationTokenSource') { Bad '下载不支持取消（无法中断）' }
if ($updPs -notmatch 'TotalSeconds -gt 45') { Bad '没有下载停滞看门狗' }
if ($updPs -notmatch 'PartPath') { Bad '更新下载没有 .part 续传文件' }
# 2.1.9 / M3：setup 全源失败后的 wrapper 回退
$entryPs = Get-Content (Join-Path $root 'src\PerfCapture.ps1') -Raw -Encoding UTF8
if ($entryPs -notmatch '68-UpdateWrapper\.ps1') { Bad '入口没有加载 wrapper 助手' }
if ($updPs -notmatch 'New-UpdateAssetInfo') { Bad '检查更新没有登记 wrapper 回退资产' }
if ($updPs -notmatch 'Start-UpdateDownload -Name \(\[string\]\$fb\.Name\)') { Bad 'setup 失败后没有自动改用 wrapper' }
if ($updPs -notmatch 'Expand-UpdateWrapper') { Bad 'wrapper 下载完成后没有解压校验' }
if ($updPs -notmatch 'Schedule-UpdateUnpackCleanup') { Bad '安装后没有清理解包目录' }
if ($updPs -notmatch '\$ProbeMs') { Bad '更新下载没有源探测预算（会逐个源等超时）' }
if ($provPs -notmatch 'Select-ProvisionSources') { Bad '扩展供应层没有源探测（多源仍逐个等超时）' }
# M1：系统代理显式化——助手必须存在、入口必须加载、两个后台 worker 都要注入它
if (-not (Test-Path (Join-Path $root 'src\app\06-NetProxy.ps1'))) { Bad '缺 06-NetProxy.ps1（系统代理显式化助手）' }
if ($entryPs -notmatch '06-NetProxy\.ps1') { Bad 'PerfCapture.ps1 未加载 06-NetProxy.ps1' }
if ($updPs -notmatch 'NetProxyHelper' -or $provPs -notmatch 'NetProxyHelper') { Bad '更新/扩展 worker 未注入代理助手源码' }
if ($updPs -notmatch 'Set-RequestProxy' -or $provPs -notmatch 'Set-RequestProxy') { Bad '下载请求没有显式设置代理' }
if ($updPs -notmatch 'retry probe direct' -or $provPs -notmatch 'retry probe direct') { Bad '代理失败时缺直连回退分支' }
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
        # 开发期 VERSION 领先于已发布清单是正常状态（批次未发版）；清单只在 pack.ps1 发版时重生成。
        # 清单版本落后 → Warn 提醒待发版；清单版本超前 → Bad（VERSION 回退属异常）。
        if ($man.version -ne $verFile) {
            try {
                if ([version]$man.version -gt [version]$verFile) { Bad "清单版本 $($man.version) 超前于 VERSION $verFile（版本回退？）" }
                else { Warn "清单版本 $($man.version) 落后于 VERSION $verFile（未发版，发版时跑 pack.ps1 重生成）" }
            } catch { Bad "清单版本 $($man.version) 与 VERSION $verFile 不一致" }
        }
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
if ($metPs -match 'cpuTemp = \$false') { Bad 'CPU 温度仍是恒 false 占位（v2.1.10 起应由真实样本校正）' }
if ($metPs -notmatch 'Get-VendorCpuTempSnapshot') { Bad 'CPU 温度未接入厂商固件通道' }
if ($metPs -notmatch 'Get-CpuThrottleState') { Bad 'CPU 降频未接入 Windows 事件日志' }
if ($metPs -notmatch 'VendorReaderCode' -or $metPs -notmatch 'ThrottleReaderCode') { Bad '采样 runspace 未注入平台/温度/降频模块源码' }
if ($metPs -notmatch 'GetSystemTimes|GlobalMemoryStatusEx') { Bad '缺少 Win32 只读采集（P/Invoke）' }
if ($metPs -notmatch 'PdhAddEnglishCounterW') { Bad 'CPU 频率没有走 PDH 英文计数器（本地化系统会读不到）' }
if ($metPs -match 'CpuMhz\(\)') { Bad '旧的 CallNtPowerInformation 频率口径又回来了（本机只给 2007/2501 粗值）' }
# 内置采样引擎不依赖外部注入/传感器驱动（RTSS 经扩展中心 opt-in，读共享内存，
# 只在 80-Extensions/rtss-shm 侧出现；35-Metrics 里只允许「数据源仲裁」注释提及，不得直连）。
foreach ($forbidden in 'OpenHardwareMonitor', 'LibreHardwareMonitor', 'inpainted', 'SetWindowsHookEx', 'WriteProcessMemory') {
    if ($metPs -match [regex]::Escape($forbidden)) { Bad "35-Metrics.ps1 里出现了不该有的依赖：$forbidden" }
}
# RTSS 相关只允许出现在「数据源仲裁/扩展源」注释里，不允许出现 OpenFileMapping/PInvoke 直连
if ($metPs -match 'OpenFileMapping|MemoryMappedFile.*RTSS|RivaTuner') { Bad '35-Metrics.ps1 不应直连 RTSS 共享内存（应经 80-Extensions 的 Get-RtssFrameSnapshot）' }
if ($metPs -notmatch 'fpsSource') { Bad '35-Metrics.ps1 缺 fpsSource 数据源仲裁字段' }
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

# ---------- 5n-2. 平台覆盖与数据源规则（v2.1.10） ----------
# 规则先行：没有规则文档就不允许有对应实现（防止「先写功能、后补口径」）
$ruleDoc = Join-Path $root '数据源与平台覆盖规则.md'
if (-not (Test-Path $ruleDoc)) { Bad '缺少《数据源与平台覆盖规则.md》（数据源必须先有规则）' }
else {
    $ruleTxt = Get-Content $ruleDoc -Raw -Encoding UTF8
    foreach ($need in 'Windows 10 1809', 'Intel', 'AMD', 'NVIDIA', 'LENOVO_OTHER_METHOD', 'Event ID 37', '禁止') {
        if ($ruleTxt -notmatch [regex]::Escape($need)) { Bad "规则文档缺关键条款：$need" }
    }
}
$platPs = Get-Content (Join-Path $root 'src\app\platform-rules.ps1') -Raw -Encoding UTF8
foreach ($need in 'Get-PlatformProfile', 'Get-CpuVendorName', 'Get-GpuVendorName', 'unsupportedCpu', 'unsupportedGpu', 'PlatformMinBuild') {
    if ($platPs -notmatch [regex]::Escape($need)) { Bad "platform-rules.ps1 缺 $need" }
}
$venPs = Get-Content (Join-Path $root 'src\app\vendor-sensor.ps1') -Raw -Encoding UTF8
foreach ($need in 'LENOVO_OTHER_METHOD', '0x05040000', 'Get-VendorCpuTempSnapshot', 'Get-VendorTempAvailability', 'vendorNotSupported') {
    if ($venPs -notmatch [regex]::Escape($need)) { Bad "vendor-sensor.ps1 缺 $need" }
}
# 红线：只读。写接口（SetFeatureValue）只允许出现在注释里，不允许被调用。
if ($venPs -match 'Invoke-CimMethod[^\r\n]*SetFeatureValue|MethodName\s+["'']SetFeatureValue') {
    Bad 'vendor-sensor.ps1 调用了 SetFeatureValue（可改温度墙/功耗墙，规则禁止）'
}
# 禁止用 ACPI 热区冒充核心温度（规则 §2）。
# 注意：类名允许出现在 vendor-sensor.ps1 的「通道目录」里（标记 evidence=banned，用于向用户解释
# 「为什么本机明明有这个类却不用」）。真正禁止的是**读取它的值**，所以这里断言的是读取痕迹。
foreach ($src in @($venPs, $platPs, $metPs)) {
    if ($src -match 'CurrentTemperature') { Bad '读取了 ACPI 热区的 CurrentTemperature（不是核心温度，规则禁止）' }
    if ($src -match 'Get-CimInstance[^\r\n]*MSAcpi_ThermalZoneTemperature|Invoke-CimMethod[^\r\n]*MSAcpi_ThermalZoneTemperature') {
        Bad '对 ACPI 热区发起了实例/方法调用（不是核心温度，规则禁止）'
    }
}
# 降频只准读事件日志，不准读 MSR / 内核
$thrPs = Get-Content (Join-Path $root 'src\app\cpu-throttle.ps1') -Raw -Encoding UTF8
foreach ($need in 'Microsoft-Windows-Kernel-Processor-Power', 'CapDurationInSeconds', 'Get-CpuThrottleSummary', 'throttleLogUnavailable') {
    if ($thrPs -notmatch [regex]::Escape($need)) { Bad "cpu-throttle.ps1 缺 $need" }
}
if ($thrPs -match 'IA32_THERM_STATUS|Rdmsr|NtQuerySystemInformation') { Bad 'cpu-throttle.ps1 试图读 MSR（需内核驱动，规则禁止）' }
# 入口必须加载三个模块（顺序：platform 先于 vendor）
$entryPsX = Get-Content (Join-Path $root 'src\PerfCapture.ps1') -Raw -Encoding UTF8
foreach ($need in 'platform-rules.ps1', 'vendor-sensor.ps1', 'cpu-throttle.ps1') {
    if ($entryPsX -notmatch [regex]::Escape($need)) { Bad "入口未加载 $need" }
}
$iPlat = $entryPsX.IndexOf('platform-rules.ps1')
$iVen = $entryPsX.IndexOf('vendor-sensor.ps1')
if ($iPlat -lt 0 -or $iVen -lt 0 -or $iPlat -gt $iVen) { Bad '入口加载顺序错误（platform-rules 必须在 vendor-sensor 之前）' }
# 指标字典：三条指标必须可采，且来源写对
$dictObj = Get-Content (Join-Path $root 'capture-metrics.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$ctMetric = @($dictObj.metrics | Where-Object { $_.id -eq 'cpu.temp' })
$thMetric = @($dictObj.metrics | Where-Object { $_.id -eq 'cpu.throttle' })
$ttMetric = @($dictObj.metrics | Where-Object { $_.id -eq 'thermal.cpuThermalThrottle' })
if ($ctMetric.Count -ne 1 -or $ctMetric[0].status -ne 'ok' -or $ctMetric[0].src -ne 'vendorwmi') { Bad 'cpu.temp 指标状态/来源不对（应 ok + vendorwmi）' }
if ($thMetric.Count -ne 1 -or $thMetric[0].status -ne 'ok' -or $thMetric[0].src -ne 'winevent') { Bad 'cpu.throttle 指标状态/来源不对（应 ok + winevent）' }
if ($ttMetric.Count -ne 1 -or $ttMetric[0].status -ne 'ok' -or $ttMetric[0].src -ne 'winevent') { Bad 'thermal.cpuThermalThrottle 指标状态/来源不对（应 ok + winevent）' }
# 采集引擎：必须真的把温度和降频写进汇总
$engPs = Get-Content (Join-Path $root 'src\engine\Measure-GamePerf.ps1') -Raw -Encoding UTF8
foreach ($need in 'cpu_thermal', 'cpu_temp_c', 'Get-CpuThrottleSummary', 'temp_state', 'throttle_count') {
    if ($engPs -notmatch [regex]::Escape($need)) { Bad "采集引擎缺 CPU 温度/降频汇总：$need" }
}
# 前端：实时页温度行必须接真实字段（不允许仍写死 null）
$rtJsX = Get-Content (Join-Path $root 'ui\js\realtime.js') -Raw -Encoding UTF8
if ($rtJsX -notmatch 'valueOf:\s*\(s\)\s*=>\s*s\.cpuTemp') { Bad 'realtime.js 的 CPU 温度行仍不是真实字段' }
$repJs = Get-Content (Join-Path $root 'ui\js\report.js') -Raw -Encoding UTF8
foreach ($need in "cpuThermal", "cpuThrottleText", "'cpu.temp'", "'cpu.throttle'", 'thermal.cpuThermalThrottle') {
    if ($repJs -notmatch [regex]::Escape($need)) { Bad "report.js 缺 CPU 温度/降频渲染：$need" }
}

# ---- 2.1.12 数据可信度与条件指纹 ----
# 判定模块必须是纯函数（探针直接 dot-source 它）：一旦混进 CIM / 事件日志 / 注册表读写就不可测了
$qualMod = Join-Path $root 'src\app\quality-rules.ps1'
if (-not (Test-Path -LiteralPath $qualMod)) { Bad '缺少 src\app\quality-rules.ps1' }
$qualPs = if (Test-Path -LiteralPath $qualMod) { Get-Content $qualMod -Raw -Encoding UTF8 } else { '' }
if ($qualPs -notmatch 'function\s+Get-CaptureQuality') { Bad 'quality-rules.ps1 没有 Get-CaptureQuality' }
foreach ($impure in 'Get-CimInstance', 'Get-WinEvent', 'Get-ItemProperty', 'Start-Process') {
    if ($qualPs -match [regex]::Escape($impure)) { Bad "quality-rules.ps1 必须是纯函数，不许调用 $impure" }
}
# 引擎：点源该模块，并把可信度与指纹写进汇总
if ($engPs -notmatch [regex]::Escape('quality-rules.ps1')) { Bad '采集引擎没有点源 quality-rules.ps1' }
foreach ($need in 'Get-CaptureQuality', 'quality          = $quality', 'driver_version', 'bios_version', 'os_version', 'schema_version   = 4') {
    if ($engPs -notmatch [regex]::Escape($need)) { Bad "采集引擎缺数据可信度/指纹：$need" }
}
if ($engPs -notmatch 'ConvertTo-Json\s+-Depth\s+6') { Bad '报告 JSON 深度不足（quality.checks 会被压成字符串）' }
if ($engPs -notmatch '\$qualHtml') { Bad '导出 HTML 没有接入可信度横幅' }
# 字典：三项指纹指标必须可采并写明来源
foreach ($fid in 'env.driverVersion', 'env.osVersion', 'env.biosVersion') {
    $m = @($dictObj.metrics | Where-Object { $_.id -eq $fid })
    if ($m.Count -ne 1) { Bad "指标字典缺 $fid" }
    elseif ($m[0].status -ne 'ok') { Bad "$fid 应为 status=ok（取不到时由报告写明原因）" }
}
if (@($dictObj.metrics | Where-Object { $_.id -eq 'env.driverVersion' })[0].src -ne 'nvsmi') { Bad 'env.driverVersion 来源应为 nvsmi' }
# 前端：横幅只在有触发项时出现，未知 code 不许猜文案
if ($repJs -notmatch 'function\s+qualityBanner') { Bad 'report.js 缺 qualityBanner' }
if ($repJs -notmatch 'r\.quality') { Bad 'report.js 没有读取 summary.quality' }
if ($repJs -notmatch 'report\.quality\.fewSamples') { Bad 'report.js 没有映射 fewSamples 文案' }
# 三语：每个质量键都要有三种语言的条目（同一文件内出现 3 次）
foreach ($qk in 'report.quality.blockedTitle', 'report.quality.cautionTitle', 'report.quality.fewSamples',
                'report.quality.stalled', 'report.quality.partial', 'report.quality.targetLost',
                'report.quality.gpuSparse', 'report.naWhy.noDriverVersion') {
    $n = ([regex]::Matches($i18nText, [regex]::Escape("'" + $qk + "'"))).Count
    if ($n -lt 3) { Bad "i18n 的 $qk 只有 $n 种语言（应 3）" }
}

# ---- 2.1.13 历史报告库 ----
$repMod = Join-Path $root 'src\app\62-Reports.ps1'
if (-not (Test-Path -LiteralPath $repMod)) { Bad '缺少 src\app\62-Reports.ps1' }
$repPs = if (Test-Path -LiteralPath $repMod) { Get-Content $repMod -Raw -Encoding UTF8 } else { '' }
foreach ($fn in 'Get-ReportIndex', 'Resolve-ReportFile', 'Remove-ReportFiles', 'Get-ReportFiles', 'Invoke-ReportCommand') {
    if ($repPs -notmatch [regex]::Escape('function ' + $fn)) { Bad "62-Reports.ps1 缺函数 $fn" }
}
# 删除必须走回收站，探针用的 -Permanent 是唯一例外
if ($repPs -notmatch 'SendToRecycleBin') { Bad '报告删除必须走回收站' }
if ($entryPsX -notmatch [regex]::Escape('62-Reports.ps1')) { Bad '入口未加载 62-Reports.ps1' }
foreach ($cmd in 'reportsList', 'reportDetail', 'reportCompare', 'reportOpenFile', 'reportDelete') {
    if ($capPs -notmatch [regex]::Escape("'" + $cmd + "'")) { Bad "命令白名单缺 $cmd" }
}
# 页面与前端
if ($idx -notmatch 'data-page="reports"') { Bad 'index.html 缺历史报告页' }
if ($idx -notmatch 'id="repList"') { Bad 'index.html 缺报告列表容器 repList' }
if ($idx -notmatch 'css/reports\.css') { Bad 'index.html 没有引入 reports.css' }
if ($idx -notmatch 'js/reports\.js') { Bad 'index.html 没有引入 reports.js' }
$repJsPath = Join-Path $root 'ui\js\reports.js'
if (-not (Test-Path -LiteralPath $repJsPath)) { Bad '缺少 ui\js\reports.js' } else {
    $repJsText = Get-Content $repJsPath -Raw -Encoding UTF8
    foreach ($need in 'PerfReports', 'reportCompare', 'qualityBadge', 'cmpBlocked') {
        if ($repJsText -notmatch [regex]::Escape($need)) { Bad "reports.js 缺 $need" }
    }
    # 红线：条件不可比时不许出现百分比结论（必须有 blocked 分支）
    if ($repJsText -notmatch 'blocked\s*\?\s*') { Bad 'reports.js 缺「不可比就不给百分比」的分支' }
    # 回归守卫（2.1.13 实测踩坑）：bridge 的 send() 只收一个对象，写成 send('cmd', {...}) 会被宿主静默丢弃
    if ($repJsText -match "send\(\s*'") { Bad 'reports.js 不得用 send(字符串, 参数)——bridge.send 只接受 {cmd:...} 对象' }
    if ($repJsText -notmatch 'function sendCmd') { Bad 'reports.js 缺 sendCmd 包装（消息体形状的唯一出口）' }
    if (-not (Test-Path (Join-Path $root 'tests\probe-reports-ui.js'))) { Bad '缺少 tests\probe-reports-ui.js（消息体形状探针）' }
}
if ((Get-Content (Join-Path $root 'ui\js\bridge.js') -Raw -Encoding UTF8) -notmatch 'PerfReports') { Bad 'bridge.js 没有分发报告库消息' }
# i18n：本批新增键必须三语齐全（抽查关键文案）
foreach ($rk in 'nav.reports', 'reports.title', 'reports.cmpBlocked', 'reports.cmpSame', 'reports.delete') {
    $n = ([regex]::Matches($i18nText, [regex]::Escape("'" + $rk + "'"))).Count
    if ($n -lt 3) { Bad "i18n 的 $rk 只有 $n 种语言（应 3）" }
}

# ---- 2.1.15 卡顿时刻快照 ----
$scMod = Join-Path $root 'src\app\stutter-context.ps1'
if (-not (Test-Path -LiteralPath $scMod)) { Bad '缺少 src\app\stutter-context.ps1' }
$scPs = if (Test-Path -LiteralPath $scMod) { Get-Content $scMod -Raw -Encoding UTF8 } else { '' }
if ($scPs -notmatch 'function\s+Get-StutterContext') { Bad 'stutter-context.ps1 没有 Get-StutterContext' }
# 纯函数：不许有 IO / 采集调用（探针直接 dot-source 它）
foreach ($impure in 'Get-Content', 'Import-Csv', 'Get-CimInstance', 'Start-Process', 'Get-ChildItem') {
    if ($scPs -match [regex]::Escape($impure)) { Bad "stutter-context.ps1 必须是纯函数，不许调用 $impure" }
}
if ($engPs -notmatch [regex]::Escape('stutter-context.ps1')) { Bad '采集引擎没有点源 stutter-context.ps1' }
if ($engPs -notmatch 'Get-StutterContext') { Bad '采集引擎没有调用 Get-StutterContext' }
if ($engPs -notmatch 'context\s*=\s*\$stutterCtx') { Bad '报告 JSON 没写入 stutter.context' }
if ($engPs -notmatch '\$secStutter') { Bad '导出 HTML 没有卡顿时刻板块' }
if ($engPs -notmatch '\$markSvg') { Bad '帧时间曲线没有卡顿位置标注' }
if ($repJs -notmatch 'function\s+stutterContextBlock') { Bad 'report.js 缺 stutterContextBlock' }
if ($repJs -notmatch 'marks') { Bad 'report.js 没有把卡顿位置传给曲线' }
foreach ($sk in 'report.sc.title', 'report.sc.cap', 'report.sc.noSamples') {
    $n = ([regex]::Matches($i18nText, [regex]::Escape("'" + $sk + "'"))).Count
    if ($n -lt 3) { Bad "i18n 的 $sk 只有 $n 种语言（应 3）" }
}
if (-not (Test-Path (Join-Path $root 'tests\probe-stutter-context.ps1'))) { Bad '缺少 tests\probe-stutter-context.ps1' }

# ---- 2.1.16 流程摩擦：全局热键 / 再采一次 / 完成提醒 ----
$hkMod = Join-Path $root 'src\app\52-Hotkeys.ps1'
if (-not (Test-Path -LiteralPath $hkMod)) { Bad '缺少 src\app\52-Hotkeys.ps1' }
$hkPs = if (Test-Path -LiteralPath $hkMod) { Get-Content $hkMod -Raw -Encoding UTF8 } else { '' }
foreach ($fn in 'Register-PerfHotkeys', 'Unregister-PerfHotkeys', 'Invoke-HotkeyCommand', 'Get-HotkeyVk', 'Flash-PerfTaskbar') {
    if ($hkPs -notmatch [regex]::Escape('function ' + $fn)) { Bad "52-Hotkeys.ps1 缺函数 $fn" }
}
if ($hkPs -notmatch 'RegisterHotKey') { Bad '52-Hotkeys.ps1 未用 RegisterHotKey（不许用全局键盘钩子）' }
if ($hkPs -match 'SetWindowsHookEx|GetAsyncKeyState') { Bad '52-Hotkeys.ps1 不许用键盘钩子/轮询键状态' }
# 红线：热键回调里不能直接开采集（参数会与界面走岔），只能通知前端
if ($hkPs -notmatch "type = 'hotkey'") { Bad '热键回调必须只发 hotkey 消息给前端' }
if ($hkPs -match 'Start-Capture') { Bad '热键回调不得直接调用 Start-Capture' }
if ($entryPsX -notmatch [regex]::Escape('52-Hotkeys.ps1')) { Bad '入口未加载 52-Hotkeys.ps1' }
foreach ($cmd in 'setHotkeys', 'getHotkeys') {
    if ($capPs -notmatch [regex]::Escape("'" + $cmd + "'")) { Bad "命令白名单缺 $cmd" }
}
if ($capPs -notmatch 'Register-PerfHotkeys') { Bad 'ready 时没有按配置注册热键' }
if ((Get-Content (Join-Path $root 'src\app\90-Main.ps1') -Raw -Encoding UTF8) -notmatch 'Unregister-PerfHotkeys') { Bad '关闭窗口时没有注销热键' }
if ($capPs -notmatch 'Flash-PerfTaskbar 3') { Bad '采集结束没有任务栏提醒' }
# 前端：再采一次 / 每游戏记忆 / 热键开关
if ($idx -notmatch 'id="btnRerun"') { Bad 'index.html 缺「再采一次」按钮' }
if ($idx -notmatch 'id="chkHotkeys"') { Bad '设置页缺热键开关' }
$mainJs = Get-Content (Join-Path $root 'ui\js\main.js') -Raw -Encoding UTF8
foreach ($need in 'GAME_PREFS_KEY', 'applyGamePref', 'PerfHotkeyAction', 'btnRerun') {
    if ($mainJs -notmatch [regex]::Escape($need)) { Bad "main.js 缺 $need" }
}
if ((Get-Content (Join-Path $root 'ui\js\bridge.js') -Raw -Encoding UTF8) -notmatch "'hotkey'") { Bad 'bridge.js 没有分发 hotkey 消息' }
if ((Get-Content (Join-Path $root 'ui\js\settings.js') -Raw -Encoding UTF8) -notmatch 'PerfHotkeysUI') { Bad 'settings.js 没有热键状态绑定' }
foreach ($k in 'capture.rerun', 'settings.hotkeys', 'settings.hotkeyStart') {
    $n = ([regex]::Matches($i18nText, [regex]::Escape("'" + $k + "'"))).Count
    if ($n -lt 3) { Bad "i18n 的 $k 只有 $n 种语言（应 3）" }
}
if (-not (Test-Path (Join-Path $root 'tests\probe-hotkeys.ps1'))) { Bad '缺少 tests\probe-hotkeys.ps1' }

# ---- 2.1.17 判读增强：限制类型判读 / 后台干扰 Top 3 ----
$limMod = Join-Path $root 'src\app\limit-rules.ps1'
$bgMod  = Join-Path $root 'src\app\bgproc.ps1'
if (-not (Test-Path -LiteralPath $limMod)) { Bad '缺少 src\app\limit-rules.ps1' }
if (-not (Test-Path -LiteralPath $bgMod))  { Bad '缺少 src\app\bgproc.ps1' }
$limPs = if (Test-Path -LiteralPath $limMod) { Get-Content $limMod -Raw -Encoding UTF8 } else { '' }
$bgPs  = if (Test-Path -LiteralPath $bgMod)  { Get-Content $bgMod -Raw -Encoding UTF8 } else { '' }
$repCss17 = Get-Content (Join-Path $root 'ui\css\report.css') -Raw -Encoding UTF8
foreach ($fn in 'Get-LimitType', 'ConvertTo-LimitNum') { if ($limPs -notmatch ('function ' + $fn)) { Bad "limit-rules.ps1 缺函数 $fn" } }
foreach ($fn in 'Get-BackgroundTop', 'ConvertTo-BgNum') { if ($bgPs -notmatch ('function ' + $fn)) { Bad "bgproc.ps1 缺函数 $fn" } }
# 纯函数红线：判定/聚合模块不得做 IO，探针才能独立验证
foreach ($p in @(@($limPs, 'limit-rules.ps1'), @($bgPs, 'bgproc.ps1'))) {
    if ($p[0] -match 'Get-WinEvent|Get-CimInstance|Get-Process|Out-File|Set-Content|Invoke-WebRequest') {
        Bad ($p[1] + ' 不是纯函数（出现 IO 调用）')
    }
}
# 「无法区分」优先：信息不足时必须说无法区分，不能说「未观察到限制」
if ($limPs -notmatch "kind = 'indistinct'") { Bad 'limit-rules.ps1 缺少 indistinct 结论' }
if ($limPs -notmatch 'noData') { Bad 'limit-rules.ps1 缺少 noData 原因码（数据不可用）' }
if ($limPs -notmatch 'cpuEventUnknown') { Bad 'limit-rules.ps1 缺少 CPU 事件原因不明分支' }
$engPs17 = Get-Content (Join-Path $root 'src\engine\Measure-GamePerf.ps1') -Raw -Encoding UTF8
foreach ($need in 'limit-rules.ps1', 'bgproc.ps1', '$bgCsv', '$collectBgProc', 'Get-LimitType', 'Get-BackgroundTop',
                  'limit            = $limit', 'background_proc  = $bgProc', '$secLimit', '$secBg') {
    if ($engPs17 -notmatch [regex]::Escape($need)) { Bad "引擎未接线 $need" }
}
if ($engPs17 -notmatch "kind = 'indistinct'") { Bad '引擎判定模块缺失时也必须给 indistinct' }
# 后台采样只读进程 CPU 时间，不许碰其它进程 GPU
$repCss17 = Get-Content (Join-Path $root 'ui\css\report.css') -Raw -Encoding UTF8
$bgBlock = ''
if ($engPs17 -match '(?s)if \(\$wantBgProc -and \(\(\$tick % 5\).*?\$tick\+\+') { $bgBlock = $Matches[0] }
if (-not $bgBlock -or $bgBlock -notmatch 'TotalProcessorTime') { Bad '后台采样未用 TotalProcessorTime 差分' }
if ($bgBlock -match 'Get-Counter|nvidia-smi|NvGpu|gpu_') { Bad '后台采样不得读取其它进程的 GPU' }
foreach ($need in 'limitBlock', 'bgProcBlock', 'limitEvidenceLabel', 'rp-bg-sub') {
    if ($repJs -notmatch [regex]::Escape($need)) { Bad "report.js 缺 $need" }
}
if ($repCss17 -notmatch '\.rp-bg-sub') { Bad 'report.css 缺后台干扰辅助样式' }
foreach ($k in 'diag.limit.thermal', 'diag.limit.indistinct', 'diag.limitWhy.noData', 'diag.limitEvidence',
               'report.bgProc.title', 'report.bgProc.cap', 'capture.item.bgproc') {
    $n = ([regex]::Matches($i18nText, [regex]::Escape("'" + $k + "'"))).Count
    if ($n -lt 3) { Bad "i18n 的 $k 只有 $n 种语言（应 3）" }
}
foreach ($tf in 'probe-limit-rules.ps1', 'probe-bgproc.ps1', 'probe-report-verdicts.js') {
    if (-not (Test-Path (Join-Path $root ('tests\' + $tf)))) { Bad ('缺少 tests\' + $tf) }
}

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
if ((Get-Content (Join-Path $root 'src\PerfCapture.ps1') -Raw -Encoding UTF8) -notmatch "'55-Overlay.ps1'") { Bad '入口没有加载 55-Overlay.ps1' }
# 批次 B：视图切换 + 曲线 + 浮窗
foreach ($need in 'rt-views', 'svgPath', 'cpuMhzMax', 'overlayToggle') {
    if ($rtJs -notmatch [regex]::Escape($need)) { Bad "realtime.js 缺 $need（批次 B）" }
}
if ($idx -notmatch 'rt-views') { Bad 'index.html 缺视图切换按钮组' }
if ($idx -notmatch 'id="btnOverlay"') { Bad 'index.html 缺浮窗按钮' }
if ($brJs -notmatch 'overlayState') { Bad 'bridge.js 没有分发 overlayState' }
$ovPs = Get-Content (Join-Path $root 'src\app\55-Overlay.ps1') -Raw -Encoding UTF8
foreach ($need in 'Show-Overlay', 'Hide-Overlay', 'Toggle-Overlay', 'GetAsyncKeyState', 'opacity') {
    if ($ovPs -notmatch [regex]::Escape($need)) { Bad "55-Overlay.ps1 缺 $need" }
}
# 浮窗也不许装键盘钩子/注入
foreach ($forbidden in 'SetWindowsHookEx', 'WriteProcessMemory', 'CreateRemoteThread') {
    if ($ovPs -match [regex]::Escape($forbidden)) { Bad "55-Overlay.ps1 出现不该有的 $forbidden" }
}
foreach ($key in 'realtime.view.chart', 'realtime.row.maxclock', 'realtime.overlay') {
    if ($i18nText -notmatch [regex]::Escape("'" + $key + "'")) { Bad "i18n 缺 $key" }
}
if ($capPs -notmatch "'overlayToggle'") { Bad '60-Capture.ps1 没登记 overlayToggle 命令' }
# 2.1.7：浮窗拖动锁（用户要求「可禁用鼠标拖动」）
# 三条一起查：宿主有锁变量并真的在拖动处理器里判、界面有开关、前端绑定并回传。
if ($ovPs -notmatch 'OverlayLocked') { Bad '55-Overlay.ps1 缺拖动锁状态（OverlayLocked）' }
if ($ovPs -notmatch 'if \(\$script:OverlayLocked\) \{ return \}') { Bad '拖动处理器没有判拖动锁' }
if ($ovPs -notmatch 'locked = \[bool\]') { Bad 'overlayState 没有回传 locked' }
if ($idx -notmatch 'id="ovLockDrag"') { Bad 'index.html 缺「禁用鼠标拖动」开关' }
if ($rtJs -notmatch 'ovLockDrag') { Bad 'realtime.js 没有绑定拖动锁开关' }

# 2.1.11：浮窗 CPU 温度不许再写死 locked。
# 2.1.10 已接入厂商固件通道，写死会让联想机型「报告里有温度、浮窗却勾不上」。
# 判定必须按平台能力动态算（非联想才灰掉），且要有独立的判定函数供状态回传复用。
if ($ovPs -match 'key = ''cputemp''[^\r\n]*locked = \$true') {
    Bad '浮窗把 cputemp 写死 locked（应按平台能力判定）'
}
if ($ovPs -notmatch "dynamic = 'temp'") { Bad '浮窗 cputemp 缺 dynamic 能力判定' }
if ($ovPs -notmatch 'Get-OverlayLockedKeys') { Bad '55-Overlay.ps1 缺 Get-OverlayLockedKeys（动态锁定）' }

# 2.1.7：扩展供应 E2（下载体验）/ E3（安装确认）的关键实现不许被回退掉
$provPs = Get-Content (Join-Path $root 'src\app\85-ExtensionProvision.ps1') -Raw -Encoding UTF8
foreach ($need in 'Get-InstallerPlan', 'Invoke-SourceOnce', 'Send-DownloadProgress', 'Stop-ExtensionProvision', 'Save-ProvisionDiagnostics', 'Get-ShmFacts') {
    if ($provPs -notmatch [regex]::Escape($need)) { Bad "85-ExtensionProvision.ps1 缺 $need（E2/E3）" }
}
if ($provPs -notmatch 'cancelSignal') { Bad '供应层缺取消信号（E2）' }
$extPs = Get-Content (Join-Path $root 'src\app\80-Extensions.ps1') -Raw -Encoding UTF8
if ($extPs -notmatch "'cancelExtensionProvision'") { Bad '80-Extensions.ps1 缺 cancelExtensionProvision 命令路由（E2）' }
# 白名单漏登记 = 前端按钮点了会被「不支持的命令」拒掉，必须一起查
if ($capPs -notmatch "'cancelExtensionProvision'") { Bad '60-Capture.ps1 命令白名单缺 cancelExtensionProvision（取消按钮会被拒）' }

# 2.1.8：网络不可达时的手动导入（选包 / 导入 / 打开下载页）三条链路必须齐全
foreach ($need in 'Select-ProvisionSources', 'stallTimeoutSec', 'probeTimeoutMs', 'pageUrl', 'keepPartOnFail') {
    if ($provPs -notmatch [regex]::Escape($need)) { Bad "85-ExtensionProvision.ps1 缺 $need（2.1.8 下载可达性）" }
}
foreach ($need in "'pickExtensionPackage'", "'importExtensionPackage'", "'openExtensionPage'") {
    if ($extPs -notmatch [regex]::Escape($need)) { Bad "80-Extensions.ps1 缺 $need（手动导入）" }
    if ($capPs -notmatch [regex]::Escape($need)) { Bad "60-Capture.ps1 缺 $need（按钮会被「不支持的命令」拒掉）" }
}
if ($extPs -notmatch 'Test-ExtensionPackageFile') { Bad '80-Extensions.ps1 缺本地包预检 Test-ExtensionPackageFile' }
$extCfg = Get-Content (Join-Path $root 'extensions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$rtssPkg = @($extCfg.extensions | Where-Object { $_.id -eq 'rtss-shm' })[0].package
if (@($rtssPkg.urls).Count -lt 2) { Bad "RTSS 只配了 $(@($rtssPkg.urls).Count) 个下载源（官方源不可达时无退路）" }
if (-not $rtssPkg.pageUrl) { Bad 'RTSS 没配官方下载页（手动导入时打不开）' }


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
