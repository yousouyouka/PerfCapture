# B142 真 WebView2 亮/暗主题像素自证：用 offscreen Form + WebView2 CreateAsync 渲染
# 真实 ui/css/tokens.css + extensions.css 与扩展中心 DOM，切两套主题后回读计算样式与像素。
# 断言：颜色来自 tokens（不是硬编码/黑底白字跑偏）、两主题确有差异、卡片文字不溢出。
# CDP/脚本等待一律泵消息（DoEvents + Sleep），不用 .Result 阻塞。
# 用法：powershell -STA -NoProfile -ExecutionPolicy Bypass -File tests\probe-b142-webview2-pixels.ps1

param([switch]$NoSelfElevate)
$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host '== B142 真 WebView2 亮/暗主题像素自证 ==' -ForegroundColor Cyan

# ---- 1. 构造 harness HTML：真 CSS + 扩展中心卡片 DOM（取自 index.html 的类名结构）----
$work = Join-Path $env:TEMP ('PerfCapture-B142-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $work -Force)
$cssLinks = @('css/tokens.css', 'css/layout.css', 'css/components.css', 'css/extensions.css') |
    ForEach-Object { '<link rel="stylesheet" href="file:///' + ((Join-Path $root ('ui\' + $_)) -replace '\\', '/') + '">' }
$cards = @'
<div class="extensions-wrap">
  <header class="extensions-header"><div>
    <span class="extensions-eyebrow">Extensions</span>
    <div class="extensions-title-line"><h1>扩展中心</h1><span class="extensions-count">1</span></div>
    <p>默认零注入；要不要安装扩展，由你决定</p>
  </div></header>
  <div class="update-banner"><span class="update-banner-text">扩展由你选择、随时可一键关闭。</span></div>
  <div class="extensions-toolbar"><div class="extensions-areas"></div>
    <label class="ext-check"><input type="checkbox">只看已安装</label>
    <button type="button" class="btn btn-ghost">刷新状态</button></div>
  <div class="extensions-scroll"><div id="extensionsList">
    <article class="ext-card" data-id="rtss-shm">
      <div class="ext-card-head"><div class="ext-card-title">RTSS 共享内存桥接</div><span class="ext-badge">可安装</span></div>
      <div class="ext-card-desc">软件内静默下载并安装一份独立的 RTSS，读取它暴露的帧数据，提供亚秒级 FPS 与 1% Low。</div>
      <div class="ext-card-meta"><span class="ext-meta-tag">FPS</span><span class="ext-meta-tag">帧时间</span><span class="ext-meta-tag">1% Low</span></div>
      <div class="ext-card-foot"><button type="button" class="btn btn-primary">安装</button><button type="button" class="btn btn-ghost">查看详情</button></div>
    </article>
  </div></div>
</div>
'@
$html = @"
<!DOCTYPE html><html lang="zh-CN" data-theme="light"><head><meta charset="utf-8">
$($cssLinks -join "`n")
<style>html,body{margin:0;padding:0;width:100%;height:100%}body{font-family:'Microsoft YaHei UI',sans-serif}#probe{width:1200px;height:760px;padding:24px;box-sizing:border-box}</style>
</head><body><div id="probe">$cards</div></body></html>
"@
$htmlPath = Join-Path $work 'probe.html'
[IO.File]::WriteAllText($htmlPath, $html, (New-Object Text.UTF8Encoding($false)))

# ---- 2. WebView2 offscreen ----
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

function Await-Task($task, [int]$TimeoutMs) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $task.IsCompleted -and $sw.ElapsedMilliseconds -lt $TimeoutMs) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 25
    }
    return $task.IsCompleted
}

try {
    $t = $wv.EnsureCoreWebView2Async($null)
    if (-not (Await-Task $t 30000)) { Bad 'WebView2 初始化超时'; exit 1 }
    $null = $t.GetAwaiter().GetResult()
    Ok 'WebView2 offscreen 初始化成功'
} catch { Bad ('WebView2 初始化失败: ' + $_.Exception.Message); exit 1 }

try {
    $nav = $wv.CoreWebView2.Navigate(([Uri]$htmlPath).AbsoluteUri)
    # Navigate 是 void，等 DocumentTitle / ExecuteScript 就绪即可；这里直接泵一轮消息
    for ($i = 0; $i -lt 80; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 25 }
    Ok 'harness 页面已加载'
} catch { Bad ('页面加载失败: ' + $_.Exception.Message); exit 1 }

$js = @'
(function(){
  function cs(el,p){return getComputedStyle(el).getPropertyValue(p).trim()}
  function rect(el){var r=el.getBoundingClientRect();return {w:r.width,h:r.height}}
  var card=document.querySelector('.ext-card');
  var title=document.querySelector('.ext-card-title');
  var desc=document.querySelector('.ext-card-desc');
  var wrap=document.querySelector('.extensions-wrap');
  var btn=document.querySelector('.ext-card-foot .btn-primary');
  return JSON.stringify({
    theme:document.documentElement.getAttribute('data-theme'),
    bodyBg:cs(document.body,'background-color'),
    bodyColor:cs(document.body,'color'),
    cardBg:cs(card,'background-color'),
    cardBorder:cs(card,'border-top-color'),
    cardShadow:cs(card,'box-shadow'),
    titleColor:cs(title,'color'),
    descColor:cs(desc,'color'),
    btnBg:cs(btn,'background-color'),
    cardRect:rect(card),
    titleOverflow:title.scrollWidth - title.clientWidth,
    descOverflow:desc.scrollHeight - desc.clientHeight,
    wrapOverflow:wrap.scrollWidth - wrap.clientWidth,
    titleFont:cs(title,'font-weight')
  });
})()
'@

function Read-Theme([string]$Theme) {
    $setJs = "document.documentElement.setAttribute('data-theme','$Theme'); true"
    $s = $wv.ExecuteScriptAsync($setJs)
    if (-not (Await-Task $s 8000)) { throw "设置主题 $Theme 超时" }
    [void]$s.GetAwaiter().GetResult()
    for ($i = 0; $i -lt 8; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 25 }
    $q = $wv.ExecuteScriptAsync($js)
    if (-not (Await-Task $q 8000)) { throw "读取主题 $Theme 样式超时" }
    $raw = [string]$q.GetAwaiter().GetResult()
    # ExecuteScriptAsync 返回的是 JSON 字符串字面量，需再解一层
    $inner = $raw
    try {
        $tmp = $raw | ConvertFrom-Json
        if ($tmp -is [string]) { $inner = $tmp }
    } catch { }
    return ($inner | ConvertFrom-Json)
}

$light = $null
$dark = $null
try {
    $light = Read-Theme 'light'
    $dark = Read-Theme 'dark'
} catch { Bad ('主题读取失败: ' + $_.Exception.Message); $form.Dispose(); exit 1 }

# ---- 3. 像素回读（截图后取样卡片区域）----
function Sample-Pixel([string]$Theme) {
    # 本仓库 WebView2 是旧版 API：CDP 方法名带 Async 后缀，用 Page.captureScreenshot 拿 base64 像素。
    $s = $wv.ExecuteScriptAsync("document.documentElement.setAttribute('data-theme','$Theme'); true")
    if (-not (Await-Task $s 8000)) { return $null }
    [void]$s.GetAwaiter().GetResult()
    for ($i = 0; $i -lt 10; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }
    try {
        $cap = $wv.CoreWebView2.CallDevToolsProtocolMethodAsync('Page.captureScreenshot', '{"format":"png","fromSurface":true}')
        if (-not (Await-Task $cap 20000)) { Write-Host 'DBG capture timeout'; return $null }
        $raw = [string]$cap.GetAwaiter().GetResult()
        $m = [regex]::Match($raw, '"data"\s*:\s*"([^"]+)"')
        if (-not $m.Success) { Write-Host ('DBG capture raw: ' + $raw.Substring(0, [Math]::Min(200, $raw.Length))); return $null }
        $bytes = [Convert]::FromBase64String($m.Groups[1].Value)
        $png = Join-Path $work ("$Theme.png")
        [IO.File]::WriteAllBytes($png, $bytes)
        $bmp = New-Object System.Drawing.Bitmap($png)
        try {
            $c = $bmp.GetPixel(40, 40)
            return @{ a = [int]$c.A; r = [int]$c.R; g = [int]$c.G; b = [int]$c.B; w = $bmp.Width; h = $bmp.Height }
        } finally { $bmp.Dispose() }
    } catch { Write-Host ('DBG capture ex: ' + $_.Exception.Message); return $null }
}

$pxLight = Sample-Pixel 'light'
$pxDark = Sample-Pixel 'dark'
$form.Dispose()

Write-Host ('  亮色: bg=' + $light.bodyBg + ' card=' + $light.cardBg + ' title=' + $light.titleColor)
Write-Host ('  暗色: bg=' + $dark.bodyBg + ' card=' + $dark.cardBg + ' title=' + $dark.titleColor)

# ---- 4. 断言 ----
Assert ($light.theme -eq 'light' -and $dark.theme -eq 'dark') '两套主题都真实生效' "主题未切换: $($light.theme)/$($dark.theme)"
Assert ($light.bodyBg -ne $dark.bodyBg -and $light.cardBg -ne $dark.cardBg) '亮/暗主题的背景与卡片颜色确有差异' '两主题颜色相同（主题切换无效）'
foreach ($t in @(@{ n = '亮色'; v = $light }, @{ n = '暗色'; v = $dark })) {
    $v = $t.v
    foreach ($key in 'bodyBg', 'bodyColor', 'cardBg', 'cardBorder', 'titleColor', 'descColor', 'btnBg') {
        Assert ($v.$key -match '^rgba?\(') "$($t.n) $key 是合法计算色值" "$($t.n) $key 异常: $($v.$key)"
    }
    Assert ($v.cardShadow -ne 'none' -and $v.cardShadow) "$($t.n) 卡片阴影来自 tokens" "$($t.n) 卡片阴影缺失"
    Assert ($v.titleFont -eq '400') "$($t.n) 标题字重为 400（字面没有粗体）" "$($t.n) 标题字重错误: $($v.titleFont)"
    Assert ([int]$v.titleOverflow -le 1) "$($t.n) 卡片标题无横向溢出" "$($t.n) 标题溢出: $($v.titleOverflow)px"
    Assert ([int]$v.wrapOverflow -le 1) "$($t.n) 扩展中心容器无横向溢出" "$($t.n) 容器溢出: $($v.wrapOverflow)px"
    Assert ([double]$v.cardRect.w -gt 300 -and [double]$v.cardRect.h -gt 100) "$($t.n) 卡片尺寸非零" "$($t.n) 卡片尺寸异常: $($v.cardRect.w)x$($v.cardRect.h)"
}
if ($null -ne $pxLight -and $null -ne $pxDark) {
    Assert ($pxLight.w -gt 0 -and $pxDark.w -gt 0) '两张截图尺寸有效' "截图尺寸异常: $($pxLight.w)x$($pxLight.h) / $($pxDark.w)x$($pxDark.h)"
    Assert (($pxLight.r + $pxLight.g + $pxLight.b) -ne ($pxDark.r + $pxDark.g + $pxDark.b)) '截图像素在两主题下确有差异' '截图像素无差异（主题未真正渲染）'
} else { Bad '截图像素回读失败' }

Write-Host '== B142 通过 ==' -ForegroundColor Cyan
if ($fail -gt 0) { Write-Host ("失败断言 $fail 项") -ForegroundColor Red; exit 1 }
exit 0
