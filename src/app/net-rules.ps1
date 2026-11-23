# 进程级网络归因聚合（2.2.1 · 报告级）
#
# 设计要点（流量监控功能规划 v2 §2 / §4）：
#   - 纯函数、无 IO：输入是 ETL 适配器吐出的行（pid / dir / size），输出聚合结果；
#     探针可直接 dot-source 验证（与 limit-rules / bgproc 同一先例）。
#   - 不猜：ETL 事件布局随系统版本漂移，适配器必须做防御校验；解析不到有效行时
#     上层如实报「无法确认」，不编 0。
#   - 口径：Event 10 = 发送（Send）、Event 11 = 接收（Receive）的字节数（按 socket 调用
#     聚合，不是逐包）；PID 归因按 socket 拥有者，短命 UDP 有天然缺口（上层如实标注）。

# 防御校验：PID 与字节数都必须在合理范围内，异常行直接丢弃（宁缺毋假）
function Test-NetEtlRow {
    param([int]$ProcId, [double]$Bytes)
    if ($ProcId -lt 4 -or $ProcId -gt 999999) { return $false }
    if ($Bytes -lt 0 -or $Bytes -gt 1GB) { return $false }
    return $true
}

function Get-NetProcessEventStats {
    param(
        [object[]]$Rows,          # @{ pid = int; dir = 'recv'|'sent'; size = double }
        [int]$GamePid = 0,
        [int]$Top = 5
    )
    $gameR = 0.0; $gameS = 0.0
    $totR = 0.0; $totS = 0.0
    $valid = 0; $invalid = 0
    $per = @{}   # pid -> @{ r; s }
    foreach ($row in $Rows) {
        $procId = 0; $bytes = -1.0; $dir = [string]$row.dir
        try { $procId = [int]$row.pid } catch { $invalid++; continue }
        if ($null -eq $row.size) { $invalid++; continue }   # [double]$null 会静默变 0，必须先挡
        try { $bytes = [double]$row.size } catch { $invalid++; continue }
        if ($dir -ne 'recv' -and $dir -ne 'sent') { $invalid++; continue }
        if (-not (Test-NetEtlRow -ProcId $procId -Bytes $bytes)) { $invalid++; continue }
        $valid++
        if ($dir -eq 'recv') { $totR += $bytes } else { $totS += $bytes }
        if (-not $per.ContainsKey($procId)) { $per[$procId] = @{ r = 0.0; s = 0.0 } }
        if ($dir -eq 'recv') {
            $per[$procId].r += $bytes
            if ($procId -eq $GamePid) { $gameR += $bytes }
        } else {
            $per[$procId].s += $bytes
            if ($procId -eq $GamePid) { $gameS += $bytes }
        }
    }
    # 其它进程按收+发合计降序取 Top；游戏进程不进 Top（它有专属字段）
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($k in $per.Keys) {
        if ($GamePid -gt 0 -and $k -eq $GamePid) { continue }
        $n = $per[$k]
        $list.Add([ordered]@{ pid = $k; recv = [math]::Round([double]$n.r, 0); sent = [math]::Round([double]$n.s, 0); total = [math]::Round([double]$n.r + [double]$n.s, 0) })
    }
    $sorted = @($list | Sort-Object -Property @{ Expression = { $_.total }; Descending = $true } | Select-Object -First $Top)
    return [ordered]@{
        validRows  = $valid
        invalidRows= $invalid
        game       = @{ recv = [math]::Round($gameR, 0); sent = [math]::Round($gameS, 0) }
        total      = @{ recv = [math]::Round($totR, 0); sent = [math]::Round($totS, 0) }
        procCount  = $per.Count
        other      = $sorted
    }
}

# 端口 → 服务推断（按端口映射，如实标注「推断」；QUIC 与 HTTPS 同为 UDP 443 不可分）
function Get-NetServiceName {
    param([int]$Port, [string]$Proto = 'TCP')
    if ($Port -le 0) { return '' }
    switch ($Port) {
        22 { return 'SSH' }
        53 { return 'DNS' }
        80 { return 'HTTP' }
        123 { return 'NTP' }
        443 { if ($Proto -eq 'UDP') { return 'HTTPS/QUIC?' } else { return 'HTTPS' } }
        1900 { return 'SSDP' }
        3306 { return 'MySQL' }
        5353 { return 'mDNS' }
        5432 { return 'PostgreSQL' }
        8080 { return 'HTTP-alt' }
        3478 { return 'STUN' }
        default { return '' }
    }
}
