# 通知集成：webhook（2.2.11 · 流量监控规划 §2-9 / §10.3 批次 E）
#
# 安全模型（复用更新通道纪律）：
#   1) 强制 HTTPS + 内置主机白名单：任意 URL 会把本工具变成 SSRF 跳板，白名单是硬边界；
#      白名单外地址一律不发，输入时拒绝并记日志。
#   2) 只发送一段文本摘要（事件 + 关键数字），不上传报告文件、不读磁盘、不带路径。
#   3) 发送在独立 runspace 异步执行（8 秒超时，15 秒强制收尾），失败只写日志与界面提示，
#      绝不影响采集 / 告警主流程。
#   4) 默认关闭，用户显式开启并填写地址后才会发出请求。
#
# 载荷按目标适配：飞书 / 企业微信 / 钉钉 / Slack / Discord 各用各的字段，多余字段有的会拒收。

# 主机白名单：host -> 适配器。只收文本消息型 webhook，不支持 GET 型（如 Telegram bot）。
$script:WebhookAllowedHosts = @{
    'open.feishu.cn'      = 'feishu'
    'open.larksuite.com'  = 'feishu'
    'qyapi.weixin.qq.com' = 'wecom'
    'oapi.dingtalk.com'   = 'dingtalk'
    'hooks.slack.com'     = 'slack'
    'discord.com'         = 'discord'
    'discordapp.com'      = 'discord'
}

$script:WebhookJobs = New-Object System.Collections.ArrayList
$script:WebhookTimer = $null

# Windows PowerShell 5.1 默认可能还是 TLS 1.0/1.1；显式并入 TLS 1.2
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

function Get-WebhookProvider([string]$Url) {
    try {
        $u = [Uri]$Url
        if ($u.Scheme -ne 'https') { return '' }
        if ($u.UserInfo) { return '' }
        $h = $u.Host.ToLowerInvariant()
        if ($script:WebhookAllowedHosts.ContainsKey($h)) { return $script:WebhookAllowedHosts[$h] }
    } catch { }
    return ''
}

function Test-WebhookUrl([string]$Url) {
    return ((Get-WebhookProvider $Url) -ne '')
}

# 按目标生成载荷；白名单外返回空串（调用方据此拒发）。
# 文本截断到 800 字：告警/采集摘要远小于此，截断只为避免异常调用把请求体撑大。
function Get-WebhookPayload([string]$Url, [string]$Text) {
    $p = Get-WebhookProvider $Url
    $msg = [string]$Text
    if ($msg.Length -gt 800) { $msg = $msg.Substring(0, 800) + '…' }
    switch ($p) {
        'feishu'   { return (@{ msg_type = 'text'; content = @{ text = $msg } } | ConvertTo-Json -Depth 4 -Compress) }
        'wecom'    { return (@{ msgtype = 'text'; text = @{ content = $msg } } | ConvertTo-Json -Depth 4 -Compress) }
        'dingtalk' { return (@{ msgtype = 'text'; text = @{ content = $msg } } | ConvertTo-Json -Depth 4 -Compress) }
        'slack'    { return (@{ text = $msg } | ConvertTo-Json -Depth 3 -Compress) }
        'discord'  { return (@{ content = $msg } | ConvertTo-Json -Depth 3 -Compress) }
    }
    return ''
}

# 发送脚本（独立 runspace 执行；单引号 here-string，禁止变量展开）
# -MaximumRedirection 0：白名单主机若返回 302，POST 体绝不跟着跳到白名单外（与更新通道同款纪律）
$script:WebhookSendScript = @'
param($Url, $Payload, $TimeoutSec)
try {
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Payload)
    Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec $TimeoutSec -MaximumRedirection 0 -ErrorAction Stop | Out-Null
    return 'ok'
} catch {
    return ('err: ' + $_.Exception.Message)
}
'@

function Receive-WebhookJobs {
    if ($script:WebhookJobs.Count -eq 0) { return }
    foreach ($j in @($script:WebhookJobs)) {
        $done = $false
        try { $done = $j.handle.IsCompleted } catch { $done = $true }
        if (-not $done -and ((Get-Date) - $j.at).TotalSeconds -lt 15) { continue }
        $result = ''
        try { $result = [string](($j.ps.EndInvoke($j.handle)) -join '') } catch { $result = 'err: ' + $_.Exception.Message }
        try { $j.ps.Dispose() } catch { }
        [void]$script:WebhookJobs.Remove($j)
        if ($result.StartsWith('ok')) {
            Write-AppLog ('webhook 已送达（' + $j.label + '）')
            try { Send-ToUi @{ type = 'webhook'; ok = $true; label = $j.label } } catch { }
        } else {
            Write-AppLog ('webhook 发送失败（' + $j.label + '）: ' + $result) 'WARN'
            try { Send-ToUi @{ type = 'webhook'; ok = $false; label = $j.label } } catch { }
            if (Get-Command Send-Log -ErrorAction SilentlyContinue) { try { Send-Log ('webhook 发送失败：' + $result) 'ln-warn' } catch { } }
        }
    }
    if ($script:WebhookJobs.Count -eq 0 -and $script:WebhookTimer) {
        try { $script:WebhookTimer.Stop(); $script:WebhookTimer.Dispose() } catch { }
        $script:WebhookTimer = $null
    }
}

function Ensure-WebhookTimer {
    if ($script:WebhookTimer) { return }
    try {
        $t = New-Object System.Windows.Forms.Timer
        $t.Interval = 400
        $t.Add_Tick({ Receive-WebhookJobs })
        $t.Start()
        $script:WebhookTimer = $t
    } catch {
        # 无头环境（探针）没有 WinForms：结果在下次发送或退出时收尾
        Write-AppLog ('webhook 回收计时器创建失败: ' + $_.Exception.Message) 'WARN'
    }
}

function Start-WebhookSend([string]$Url, [string]$Text, [string]$Label) {
    $payload = Get-WebhookPayload $Url $Text
    if (-not $payload) { return $false }
    try {
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($script:WebhookSendScript)
        [void]$ps.AddParameter('Url', $Url)
        [void]$ps.AddParameter('Payload', $payload)
        [void]$ps.AddParameter('TimeoutSec', 8)
        $h = $ps.BeginInvoke()
        [void]$script:WebhookJobs.Add(@{ ps = $ps; handle = $h; label = $Label; at = (Get-Date) })
        Ensure-WebhookTimer
        return $true
    } catch {
        Write-AppLog ('webhook 发送启动失败: ' + $_.Exception.Message) 'WARN'
        return $false
    }
}

# 事件入口：采集完成 / 流量告警。开关或事件未勾选时静默返回。
function Send-PerfWebhook([string]$Event, [string]$Text) {
    try {
        $wh = $script:Cfg.webhook
        if (-not $wh -or -not $wh.enabled) { return }
        if ($Event -eq 'capture' -and $wh.capture -eq $false) { return }
        if ($Event -eq 'netAlert' -and $wh.netAlert -eq $false) { return }
        $url = [string]$wh.url
        if (-not (Test-WebhookUrl $url)) { return }
        [void](Start-WebhookSend $url ('【PerfCapture】' + $Text) $Event)
    } catch {
        Write-AppLog ('webhook 触发失败: ' + $_.Exception.Message) 'WARN'
    }
}

# 设置页「发送测试」：优先用界面当前地址（用户可能刚改完还没落盘），其次用已保存地址；
# 不受启用开关与事件勾选限制，但地址仍必须过白名单。
function Test-PerfWebhook([string]$Url = '') {
    $u = ([string]$Url).Trim()
    if (-not $u) {
        try { $u = [string]$script:Cfg.webhook.url } catch { }
    }
    if (-not (Test-WebhookUrl $u)) {
        Send-ToUi @{ type = 'webhook'; ok = $false; label = 'test' }
        return
    }
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    if (-not (Start-WebhookSend $u ('【PerfCapture】测试消息 · ' + $stamp) 'test')) {
        Send-ToUi @{ type = 'webhook'; ok = $false; label = 'test' }
    }
}

# 退出时收尾：停掉计时器、结束未完成的发送（不让进程被后台 runspace 拖住）
function Stop-PerfWebhookJobs {
    if ($script:WebhookTimer) {
        try { $script:WebhookTimer.Stop(); $script:WebhookTimer.Dispose() } catch { }
        $script:WebhookTimer = $null
    }
    foreach ($j in @($script:WebhookJobs)) {
        try { [void]$j.ps.Stop() } catch { }
        try { $j.ps.Dispose() } catch { }
    }
    $script:WebhookJobs.Clear()
}
