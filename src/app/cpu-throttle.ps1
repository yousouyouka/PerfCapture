# CPU 降频：只读 Windows 系统事件日志
#
# 规则见《数据源与平台覆盖规则.md》§4。要点：
#   - 唯一来源：System 日志 / Microsoft-Windows-Kernel-Processor-Power / Event ID 37。
#   - Event 37 = 固件限制了处理器性能，并记录持续秒数（CapDurationInSeconds）。
#     它只说明「被限制」，不说明原因（温度/供电/BIOS 策略都可能）——文案不许写成「诊断出温度降频」。
#   - 查询失败与「查询成功但没有事件」必须分开：前者 N/A，后者才是「未记录到限速」。
#   - 不做频率推断、不读 MSR、不装驱动。

$script:KppProvider = 'Microsoft-Windows-Kernel-Processor-Power'
$script:KppEventId = 37
$script:ThrottleStateCache = $null
$script:ThrottleStateAt = [datetime]::MinValue
# 30 s：单次事件日志查询实测约 245 ms，放在采样 runspace 里 10 s 一次会明显拖慢采样节奏；
# 报告侧不依赖这个缓存（采集结束时按窗口精确统计一次），实时页只做粗粒度提示。
$script:ThrottleStateTtlSec = 30

# 纯函数：从事件 XML 解析出（组, 逻辑处理器, 本段持续秒数）。
# 独立出来是为了用合成 XML 做单元测试（不依赖真机是否真的限速过）。
function ConvertFrom-KppEventXml([string]$XmlText) {
    $out = @{ ok = $false; group = $null; number = $null; seconds = $null; detail = '' }
    if (-not $XmlText) { $out.detail = 'empty'; return $out }
    try {
        $x = [xml]$XmlText
    } catch {
        $out.detail = 'bad xml'; return $out
    }
    $nodes = @($x.Event.EventData.Data)
    if ($nodes.Count -eq 0) { $out.detail = 'no data'; return $out }
    $map = @{}
    foreach ($n in $nodes) {
        # 带 Name 的节点是 XmlElement；只有位置、没有 Name 的节点会被适配成 string
        if ($n -is [string]) { continue }
        $name = [string]$n.Name
        if ($name) { $map[$name] = [string]$n.'#text' }
    }
    $intOf = {
        param($key, $idx)
        $raw = $null
        if ($key -and $map.ContainsKey($key)) { $raw = $map[$key] }
        elseif ($idx -ge 0 -and $idx -lt $nodes.Count) {
            $node = $nodes[$idx]
            $raw = if ($node -is [string]) { [string]$node } else { [string]$node.'#text' }
        }
        $v = 0
        if ($raw -and [int]::TryParse($raw, [ref]$v)) { return $v }
        return $null
    }
    $out.group = & $intOf 'Group' 0
    $out.number = & $intOf 'Number' 1
    $out.seconds = & $intOf 'CapDurationInSeconds' 2
    $out.ok = ($null -ne $out.seconds)
    if (-not $out.ok) { $out.detail = 'no duration' }
    return $out
}

function Test-SystemEventLogReadable {
    try {
        $null = Get-WinEvent -LogName 'System' -MaxEvents 1 -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# 采集窗口内的限速汇总。
# 返回：ok / reason / count / cores / maxSeconds / firstAt / lastAt / truncated / source
function Get-CpuThrottleSummary([datetime]$Since, [int]$MaxEvents = 300) {
    $out = [ordered]@{
        ok = $false; reason = ''; count = 0; cores = 0; maxSeconds = $null
        firstAt = $null; lastAt = $null; truncated = $false
        source = 'winevent:kpp-37'; detail = ''
    }
    if (-not $Since) { $Since = (Get-Date).AddMinutes(-5) }
    $ev = @()
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{
                LogName = 'System'; ProviderName = $script:KppProvider; Id = $script:KppEventId; StartTime = $Since
            } -MaxEvents $MaxEvents -ErrorAction Stop)
    } catch {
        # 「没有匹配事件」和「日志读不了」必须分开：用一次最简单的读取来判定。
        # 不靠错误文案（系统语言会变），靠行为。
        if (Test-SystemEventLogReadable) {
            $ev = @()
        } else {
            $out.reason = 'throttleLogUnavailable'
            $out.detail = [string]$_.Exception.Message
            return $out
        }
    }
    $out.ok = $true
    $out.count = $ev.Count
    $out.truncated = ($ev.Count -ge $MaxEvents)
    if ($ev.Count -eq 0) { return $out }
    $cores = @{}
    $maxSec = 0
    $times = New-Object System.Collections.ArrayList
    foreach ($e in $ev) {
        $p = ConvertFrom-KppEventXml ([string]$e.ToXml())
        if ($null -ne $p.group -and $null -ne $p.number) { $cores[[string]$p.group + ':' + [string]$p.number] = 1 }
        if ($null -ne $p.seconds -and [int]$p.seconds -gt $maxSec) { $maxSec = [int]$p.seconds }
        if ($e.TimeCreated) { [void]$times.Add([datetime]$e.TimeCreated) }
    }
    $out.cores = $cores.Count
    $out.maxSeconds = if ($maxSec -gt 0) { $maxSec } else { $null }
    if ($times.Count -gt 0) {
        $sorted = @($times | Sort-Object)
        $out.firstAt = $sorted[0].ToString('yyyy-MM-dd HH:mm:ss')
        $out.lastAt = $sorted[$sorted.Count - 1].ToString('yyyy-MM-dd HH:mm:ss')
    }
    return $out
}

# 实时页：最近 N 秒是否有限速记录（带缓存，采样循环每秒调也只查一次 / 10 s）
function Get-CpuThrottleState([int]$WindowSeconds = 120, [switch]$Fresh) {
    $now = Get-Date
    if (-not $Fresh -and $script:ThrottleStateCache -and ($now - $script:ThrottleStateAt).TotalSeconds -lt $script:ThrottleStateTtlSec) {
        return $script:ThrottleStateCache
    }
    $s = Get-CpuThrottleSummary -Since $now.AddSeconds(-1 * [math]::Abs($WindowSeconds)) -MaxEvents 60
    $state = [ordered]@{
        ok = $s.ok
        limited = ($s.ok -and $s.count -gt 0)
        count = $s.count
        cores = $s.cores
        maxSeconds = $s.maxSeconds
        reason = $s.reason
        source = $s.source
        windowSec = $WindowSeconds
        at = $now.ToString('yyyy-MM-dd HH:mm:ss')
    }
    $script:ThrottleStateCache = $state
    $script:ThrottleStateAt = $now
    return $state
}

# 报告用一句话（中文；前端另有 i18n 版本，这里给 HTML 报告与控制台）
function Format-CpuThrottleSummary($Summary) {
    if (-not $Summary) { return 'N/A' }
    if (-not $Summary.ok) {
        switch ([string]$Summary.reason) {
            'throttleLogUnavailable' { return 'N/A（Windows 系统日志不可读）' }
            default { return 'N/A' }
        }
    }
    if ($Summary.count -le 0) { return '未记录到固件限速' }
    $txt = '已记录 ' + $Summary.count + ' 条固件限速'
    if ($Summary.cores -gt 0) { $txt += '（涉及 ' + $Summary.cores + ' 个逻辑处理器' }
    if ($null -ne $Summary.maxSeconds) {
        if ($Summary.cores -gt 0) { $txt += '，最长一次持续 ' + $Summary.maxSeconds + ' 秒）' }
        else { $txt += '（最长一次持续 ' + $Summary.maxSeconds + ' 秒）' }
    } elseif ($Summary.cores -gt 0) { $txt += '）' }
    return $txt
}
