# 与前端通信（postMessage 桥）

# ---------- 与前端通信 ----------
function Send-ToUi([hashtable]$payload) {
    if (-not $script:Core) { return }
    try {
        $json = $payload | ConvertTo-Json -Depth 6 -Compress
        $script:Core.PostWebMessageAsJson($json)
    } catch { }
}

function Send-Log([string]$text, [string]$cls = '') {
    Send-ToUi @{ type = 'log'; text = $text; cls = $cls }
}

# ---------- DevTools Protocol ----------
# 调 CDP 必须泵消息等待：直接 .Result / .Wait() 会在 UI 线程上死锁
function Invoke-DevTools([string]$method, [string]$paramsJson = '{}', [int]$timeoutMs = 15000) {
    if (-not $script:Core) { throw 'WebView2 未就绪' }
    $task = $script:Core.CallDevToolsProtocolMethodAsync($method, $paramsJson)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $task.IsCompleted) {
        if ($sw.ElapsedMilliseconds -gt $timeoutMs) { throw ('CDP 调用超时: ' + $method) }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 25
    }
    return $task.Result
}

# ---------- 执行前端脚本 ----------
# ExecuteScriptAsync 与 CDP 同规矩：不能在 WebMessageReceived 回调里 .Result（主线程死锁），
# 必须泵消息等完成。返回脚本的原始结果（JSON 字符串，例如 "true"）。
function Invoke-UiScript([string]$script, [int]$timeoutMs = 15000) {
    if (-not $script:Core) { throw 'WebView2 未就绪' }
    $task = $script:Core.ExecuteScriptAsync($script)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $task.IsCompleted) {
        if ($sw.ElapsedMilliseconds -gt $timeoutMs) { throw '前端脚本执行超时' }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 20
    }
    return $task.Result
}
