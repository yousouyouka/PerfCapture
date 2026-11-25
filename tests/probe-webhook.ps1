# webhook 纯函数与门控自检（2.2.11 · 批次 E）
# 不发起任何真实网络请求：URL 白名单、载荷结构、开关/事件门控、失败不抛异常全部用桩验证。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-webhook.ps1
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$out = New-Object System.Collections.Generic.List[string]
function Ok($m) { $out.Add('  PASS ' + $m); $script:np++ }
function Bad($m) { $out.Add('  FAIL ' + $m); $script:nf++ }

$script:np = 0; $script:nf = 0

# ---- 桩：宿主全局 ----
$script:Logs = New-Object System.Collections.ArrayList
$script:UiMsgs = New-Object System.Collections.ArrayList
function Write-AppLog([string]$m, [string]$lvl = 'INFO') { [void]$script:Logs.Add($lvl + ' ' + $m) }
function Send-ToUi($payload) { [void]$script:UiMsgs.Add($payload) }
function Send-Log([string]$m, [string]$cls = '') { }
$script:Cfg = @{ webhook = @{ enabled = $false; url = ''; capture = $true; netAlert = $true } }

# ---- dot-source 被测模块 ----
. (Join-Path $root 'src\app\58-Webhook.ps1')
Ok '58-Webhook.ps1 dot-source 成功'

# ---- 1. URL 白名单 ----
$good = @(
    'https://open.feishu.cn/open-apis/bot/v2/hook/abc',
    'https://open.larksuite.com/open-apis/bot/v2/hook/abc',
    'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc',
    'https://oapi.dingtalk.com/robot/send?access_token=abc',
    'https://hooks.slack.com/services/T000/B000/xxx',
    'https://discord.com/api/webhooks/1/abc'
)
$badUrls = @(
    'http://open.feishu.cn/open-apis/bot/v2/hook/abc',
    'https://evil.example.com/hook',
    'https://open.feishu.cn.evil.com/hook',
    'https://user:pw@open.feishu.cn/hook',
    'file:///C:/tmp/x',
    'ftp://open.feishu.cn/x',
    ''
)
$okAll = $true
foreach ($u in $good) { if (-not (Test-WebhookUrl $u)) { $okAll = $false; $out.Add('  [bad] 白名单误拒: ' + $u) } }
if ($okAll) { Ok ('白名单内 HTTPS 地址全部通过（' + $good.Count + ' 个）') } else { Bad '白名单内地址被误拒' }
$rejAll = $true
foreach ($u in $badUrls) { if (Test-WebhookUrl $u) { $rejAll = $false; $out.Add('  [bad] 应拒绝却通过: ' + $u) } }
if ($rejAll) { Ok ('白名单外 / 非 HTTPS / 带用户信息一律拒绝（' + $badUrls.Count + ' 个）') } else { Bad '存在应拒绝却通过的地址' }

# ---- 2. 载荷按目标适配 ----
$cases = @(
    @{ u = 'https://open.feishu.cn/hook/x'; keys = @('msg_type', 'content'); kind = 'feishu' },
    @{ u = 'https://qyapi.weixin.qq.com/x'; keys = @('msgtype', 'text'); kind = 'wecom' },
    @{ u = 'https://oapi.dingtalk.com/x'; keys = @('msgtype', 'text'); kind = 'dingtalk' },
    @{ u = 'https://hooks.slack.com/x'; keys = @('text'); kind = 'slack' },
    @{ u = 'https://discord.com/x'; keys = @('content'); kind = 'discord' }
)
foreach ($c in $cases) {
    $payload = Get-WebhookPayload $c.u '测试文本 ABC'
    $obj = $null
    try { $obj = $payload | ConvertFrom-Json } catch { }
    $hasKeys = $true
    foreach ($k in $c.keys) { if (-not $obj.PSObject.Properties[$k]) { $hasKeys = $false } }
    $textOk = $false
    if ($c.kind -eq 'feishu') { $textOk = ([string]$obj.content.text -eq '测试文本 ABC') }
    elseif ($c.kind -eq 'wecom' -or $c.kind -eq 'dingtalk') { $textOk = ([string]$obj.text.content -eq '测试文本 ABC') }
    elseif ($c.kind -eq 'slack') { $textOk = ([string]$obj.text -eq '测试文本 ABC') }
    elseif ($c.kind -eq 'discord') { $textOk = ([string]$obj.content -eq '测试文本 ABC') }
    if ($hasKeys -and $textOk) { Ok ('载荷结构正确: ' + $c.kind) } else { Bad ('载荷结构不对: ' + $c.kind + ' -> ' + $payload) }
}
$empty = Get-WebhookPayload 'https://evil.example.com/x' 'x'
if ($empty -eq '') { Ok '白名单外地址不生成载荷（直接拒发）' } else { Bad '白名单外地址仍生成了载荷' }

# ---- 3. 开关与事件门控（替换发送函数，确保零真实请求） ----
$script:Sent = New-Object System.Collections.ArrayList
function Start-WebhookSend([string]$Url, [string]$Text, [string]$Label) { [void]$script:Sent.Add($Label); return $true }
$validUrl = 'https://open.feishu.cn/open-apis/bot/v2/hook/abc'

$script:Cfg.webhook = @{ enabled = $false; url = $validUrl; capture = $true; netAlert = $true }
Send-PerfWebhook 'capture' 'x'
if ($script:Sent.Count -eq 0) { Ok '开关关闭时不发送' } else { Bad '开关关闭仍然发送了' }

$script:Cfg.webhook = @{ enabled = $true; url = $validUrl; capture = $false; netAlert = $true }
Send-PerfWebhook 'capture' 'x'
if ($script:Sent.Count -eq 0) { Ok '事件未勾选时不发送（capture）' } else { Bad '未勾选的 capture 事件仍然发送' }
Send-PerfWebhook 'netAlert' 'x'
if ($script:Sent.Count -eq 1 -and $script:Sent[0] -eq 'netAlert') { Ok '勾选的事件正常触发（netAlert）' } else { Bad '勾选的事件没有触发' }

$script:Cfg.webhook = @{ enabled = $true; url = 'https://evil.example.com/x'; capture = $true; netAlert = $true }
Send-PerfWebhook 'capture' 'x'
if ($script:Sent.Count -eq 1) { Ok '白名单外地址不触发发送' } else { Bad '白名单外地址仍然发送了' }

# ---- 4. 测试按钮：地址非法时回执失败，不发请求 ----
$script:UiMsgs.Clear() | Out-Null
$before = $script:Sent.Count
Test-PerfWebhook
$last = if ($script:UiMsgs.Count) { $script:UiMsgs[$script:UiMsgs.Count - 1] } else { $null }
if ($script:Sent.Count -eq $before -and $last -and $last.type -eq 'webhook' -and $last.ok -eq $false) { Ok '测试：非法地址不发请求并回执失败' } else { Bad '测试：非法地址处理不正确' }

$script:Cfg.webhook.url = $validUrl
Test-PerfWebhook
if ($script:Sent.Count -eq $before + 1 -and $script:Sent[$script:Sent.Count - 1] -eq 'test') { Ok '测试：合法地址按 test 标签发送（不受启用开关限制）' } else { Bad '测试：合法地址没有发送' }

# ---- 5. 收尾不抛异常 ----
try { Stop-PerfWebhookJobs; Ok 'Stop-PerfWebhookJobs 空队列可安全收尾' } catch { Bad ('Stop-PerfWebhookJobs 抛异常: ' + $_.Exception.Message) }

$out.Add('')
if ($script:nf -eq 0) { $out.Add("== 全部通过（$script:np 项）==") } else { $out.Add("== 失败 $script:nf 项 / 通过 $script:np 项 ==") }
[IO.File]::WriteAllLines((Join-Path $root 'tests\probe-webhook.log'), $out, (New-Object Text.UTF8Encoding($true)))
Write-Host ('完成：tests\probe-webhook.log（失败 ' + $script:nf + '）')
if ($script:nf -gt 0) { exit 1 } else { exit 0 }
