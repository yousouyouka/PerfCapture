# 网络实时采样器与持久化（2.2.0 · 流量监控阶段 1+2）
#
# 设计要点（流量监控功能规划 v2 §1）：
#   - L1 接口总量口径：每 1 秒对每块非隐藏网卡做 Get-NetAdapterStatistics 差分。
#   - 常驻监控与游戏采集完全解耦：绝不启动 PresentMon / logman / 任何 ETW 会话，不编译 C#，
#     不需要管理员权限。独立于 35-Metrics 的采样器（那台开机会拉起 PresentMon 突发窗口）。
#   - 常驻 runspace 循环采样 → ConcurrentQueue 回传 → 宿主计时器取走（复用 35-Metrics 样板）。
#   - 采不到的一律 $null（不是 0）：界面显示「—」，绝不假装有数据。
#   - 计数器回退（网卡重连 / 驱动重置）→ 该秒速率置 null 并重置基线，绝不报负数。
#   - 首秒只记基线不出速率：没有时间基准就不造数。
#
# 持久化（阶段 2）：
#   - 存储为「按日 × 按接口」累计：traffic\days.json，体量恒小（一年约 365 行），秒级明细
#     不落盘——日/月报表与今日/本月累计只需要按日聚合，逐秒 JSONL 每月数十 MB 且解析昂贵，
#     纯属浪费（对规划 v2 §1.4 的调整，理由见 CHANGELOG）。
#   - 内存累加，每 60 秒原子落盘（临时文件 + 替换）；退出时强制落盘；跨日自动翻转。
#   - 保留 400 天，更早的日期行在落盘时清除。
#   - 适配器种类（物理/虚拟）随样本更新进 meta，历史聚合据此只算物理接口。

$script:NetIntervalMs = 1000
$script:NetRingSize = 120        # 1 Hz × 120 点 ≈ 2 分钟窗口
$script:NetFlushSec = 60
$script:NetKeepDays = 400       # 默认保留天数；实际以配置 netKeepDays 为准（见 Get-NetKeepDays）
$script:NetSamples = New-Object System.Collections.ArrayList
$script:NetWorker = $null
$script:NetQueue = $null
$script:NetTimer = $null
$script:NetRunning = $false
$script:NetConsumers = @{}       # 谁在要数据：page（网络页）/ persist（持久化）/ 以后 overlay
$script:NetCaps = $null
$script:NetLoaded = $false

# ---------- 一轮采样（runspace 里执行；单引号 here-string，禁止变量展开） ----------
$script:NetSampleScript = @'
param($Queue, $Ctl)

# 网卡分类：物理（Wi-Fi / 以太网）与虚拟（VPN / 虚拟交换机）分开标，供界面与口径使用。
# 依据：Get-NetAdapter 的 Virtual 布尔 + MediaType（'Native 802.11' / '802.3'）+ 描述关键词兜底。
function Get-NetKind($m) {
    if ($null -eq $m) { return 'other' }
    try { if ($m.Virtual) { return 'virtual' } } catch { }
    $mt = ''
    $d = ''
    try { $mt = [string]$m.MediaType } catch { }
    try { $d = [string]$m.InterfaceDescription } catch { }
    if ($mt -match '802\.11' -or $d -match 'wi-?fi|wireless|802\.11') { return 'wifi' }
    if ($d -match 'bluetooth') { return 'bluetooth' }
    if ($mt -match '802\.3' -or $d -match 'ethernet|realtek|gigabit|2\.5g|10g') { return 'ethernet' }
    return 'other'
}

$meta = @{}
$metaByName = @{}   # 网卡名 -> ifIndex（裸 runspace 里统计对象没有 ifIndex 别名属性，按 Name 配对）
$prev = @{}
$wall = $null
$tick = 0
$pnames = @{}    # pid -> 进程名（连接视图用）
$dnsCache = @{}  # ip -> 主机名（'' = 已查无/未解析）；反向 DNS 默认关，开了也限预算
$dnsBudget = 0

# 端口 → 服务推断（按端口映射，如实标注；QUIC 与 HTTPS 同为 UDP 443 不可分）
function Get-NetSvc([int]$Port, [string]$Proto) {
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

# 反向 DNS：异步解析 + 700ms 预算 + 每次 tick 最多 2 个新查询，绝不阻塞采样循环
function Resolve-NetHost([string]$Ip) {
    if (-not $Ip -or $dnsCache.ContainsKey($Ip)) { return $dnsCache[$Ip] }
    if ($dnsBudget -le 0) { return '' }
    $dnsBudget--
    try {
        $t = [System.Net.Dns]::GetHostEntryAsync($Ip)
        if ($t.Wait(700)) {
            $hn = ''
            try { $hn = [string]$t.Result.HostName } catch { }
            $dnsCache[$Ip] = $hn
            return $hn
        }
        $dnsCache[$Ip] = ''
    } catch { $dnsCache[$Ip] = '' }
    return ''
}
while ($true) {
    if ($Ctl -and $Ctl.stop) { break }
    try {
        $tick++
        # 元数据（Virtual / MediaType / Status / 链路速度）变化极慢，每 5 秒刷一次就够
        if (($tick % 5) -eq 1 -or $meta.Count -eq 0) {
            $meta = @{}
            $metaByName = @{}
            foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue)) {
                try {
                    $meta[[int]$a.InterfaceIndex] = $a
                    $metaByName[[string]$a.Name] = [int]$a.InterfaceIndex
                } catch { }
            }
        }
        $now = Get-Date
        $seen = @{}
        # 注意：这里必须用「普通数组 + 普通哈希表」——PS 5.1 对装有 [ordered] 字典的
        # List[object] 做 @() 枚举会抛「Argument types do not match」（2.2.1 自检抓出的根因）
        $ifs = @()
        $dnsBudget = 2
        $wantDns = ($Ctl -and $Ctl.reverseDns)
        # 连接/会话快照（L3 口径：只列「现在谁连着谁」，不计字节）
        $conns = @()
        try {
            if (($tick % 5) -eq 1 -or $pnames.Count -eq 0) {
                $pnames = @{}
                foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
                    try { $pnames[[int]$p.Id] = [string]$p.ProcessName } catch { }
                }
            }
            foreach ($tc in @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue)) {
                if ($conns.Count -ge 100) { break }
                $op = 0
                try { $op = [int]$tc.OwningProcess } catch { }
                if ($op -le 0) { continue }
                $ra = [string]$tc.RemoteAddress
                $hn = ''
                if ($wantDns -and $ra -ne '0.0.0.0' -and $ra -ne '::') { $hn = Resolve-NetHost $ra }
                $rp = 0
                try { $rp = [int]$tc.RemotePort } catch { }
                $conns += @{
                    p  = $op
                    n  = if ($pnames.ContainsKey($op)) { $pnames[$op] } else { '' }
                    pr = 'TCP'
                    la = [string]$tc.LocalAddress; lp = [int]$tc.LocalPort
                    ra = $ra; rp = $rp
                    st = 'ESTABLISHED'
                    sv = Get-NetSvc $rp 'TCP'
                    hn = $hn
                }
            }
            foreach ($ud in @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue)) {
                if ($conns.Count -ge 100) { break }
                $op = 0
                try { $op = [int]$ud.OwningProcess } catch { }
                if ($op -le 0) { continue }
                $lp2 = 0
                try { $lp2 = [int]$ud.LocalPort } catch { }
                $conns += @{
                    p  = $op
                    n  = if ($pnames.ContainsKey($op)) { $pnames[$op] } else { '' }
                    pr = 'UDP'
                    la = [string]$ud.LocalAddress; lp = $lp2
                    ra = '*'; rp = 0
                    st = ''
                    sv = Get-NetSvc $lp2 'UDP'
                    hn = ''
                }
            }
        } catch { }
        $adStats = @(); $adErr = ''
        try { $adStats = @(Get-NetAdapterStatistics -ErrorAction SilentlyContinue) } catch { $adErr = $_.Exception.Message }
        foreach ($s in $adStats) {
            # 裸 runspace 里 Get-NetAdapterStatistics 的 ifIndex/InterfaceIndex 是类型数据
            # 提供的别名属性，不存在（2.2.1 自检抓出：ifs 永远为空的根因）——按 Name 配对元数据取索引
            $nm3 = [string]$s.Name
            $idx = if ($metaByName.ContainsKey($nm3)) { [int]$metaByName[$nm3] } else { 0 }
            if ($idx -le 1) { continue }          # 0 = 配不上/非法；1 = Loopback，不计
            $seen[$idx] = $true
            $m = if ($meta.ContainsKey($idx)) { $meta[$idx] } else { $null }
            $recvTotal = $null; $sentTotal = $null
            try { if ($null -ne $s.ReceivedBytes) { $recvTotal = [double]$s.ReceivedBytes } } catch { }
            try { if ($null -ne $s.SentBytes) { $sentTotal = [double]$s.SentBytes } } catch { }
            if ($null -eq $recvTotal -and $null -eq $sentTotal) { continue }
            $recvBps = $null; $sentBps = $null
            $status = 'unknown'
            $linkSpeed = ''
            if ($m) {
                try { $status = [string]$m.Status } catch { }
                try { $linkSpeed = ([string]$m.LinkSpeed).Trim() } catch { }
            }
            if ($recvTotal -ge 0 -and $sentTotal -ge 0) {
                $old = if ($prev.ContainsKey($idx)) { $prev[$idx] } else { $null }
                if ($old) {
                    $dt = if ($wall) { ($now - $wall).TotalSeconds } else { 0.0 }
                    if ($dt -gt 0.2) {
                        $dr = $recvTotal - [double]$old.recv
                        $ds = $sentTotal - [double]$old.sent
                        if ($dr -ge 0 -and $ds -ge 0) {
                            $recvBps = [math]::Round($dr / $dt, 0)
                            $sentBps = [math]::Round($ds / $dt, 0)
                        } else {
                            # 计数器回退 = 网卡重连或驱动重置：这一秒不报速率，重置基线
                            $prev.Remove($idx)
                        }
                    }
                }
                if (-not $old -or -not $prev.ContainsKey($idx)) {
                    $prev[$idx] = @{ recv = $recvTotal; sent = $sentTotal }
                }
            }
            $ifs += @{
                ifIndex  = $idx
                name     = if ($m) { [string]$m.Name } else { [string]$s.Name }
                desc     = if ($m) { [string]$m.InterfaceDescription } else { [string]$s.InterfaceDescription }
                kind     = Get-NetKind $m
                status   = $status
                linkSpeed= $linkSpeed
                recvBps  = $recvBps
                sentBps  = $sentBps
                recvTotal= $recvTotal
                sentTotal= $sentTotal
            }
        }
        foreach ($gone in @($prev.Keys | Where-Object { -not $seen.ContainsKey($_) })) { [void]$prev.Remove($gone) }
        $wall = $now
        # 跨 runspace 纪律（2.2.1）：样本一律序列化成 JSON 字符串入队，宿主 ConvertFrom-Json 还原。
        # 嵌套集合/字典对象跨 runspace 枚举会抛「Argument types do not match」，且装有 [ordered]
        # 字典的 List[object] 连宿主侧 @() 枚举都会炸（metrics 采样器只传标量所以没踩到）。
        $payload = @{
            at   = $now.ToString('yyyy-MM-dd HH:mm:ss')
            ifs  = $ifs
            conns= $conns
            connTruncated = ($conns.Count -ge 100)
        }
        [void]$Queue.Enqueue(($payload | ConvertTo-Json -Depth 6 -Compress))
    } catch {
        # 任何一次异常都不许弄死采样线程：丢这一秒，下秒重来
    }
    # 2.2.3：停止检测按 100ms 粒度——直接 Sleep 1000 会让关闭最多白等 1 秒
    for ($si = 0; $si -lt 10; $si++) {
        if ($Ctl -and $Ctl.stop) { break }
        Start-Sleep -Milliseconds 100
    }
}
'@

# ---------- 持久化存储 ----------
$script:NetTrafficDir = $null
$script:NetDaysPath = $null
$script:NetDays = @{}            # 'yyyy-MM-dd' -> ifIndex -> @{ r; s }（已落盘部分）
$script:NetDayAcc = @{}          # 今天未落盘的增量：ifIndex -> @{ r; s }
$script:NetDayKey = ''           # 正在累加的日期
$script:NetLastTotals = @{}      # ifIndex -> @{ r; s } 上一次计数器快照（求增量用）
$script:NetMeta = @{}            # ifIndex -> @{ name; kind }（最近一次见到的分类）
$script:NetLastFlush = $null
$script:NetUiRates = $null       # @{ recv; sent; at } 物理接口合计速率快照（浮窗 / 托盘用）
$script:NetTray = $null          # 托盘图标（tooltip 显示网速，balloon 弹告警）
$script:NetAlertedDay = ''       # 本日已告警标记（每日最多提醒一次）
$script:NetAlertedMonth = ''     # 本月已告警标记
$script:NetAlertedIf = @{}       # 'yyyy-MM-dd|接口名' -> $true（按接口每日阈值，每天一次）
$script:NetAlertStatePath = $null  # 告警状态文件：重启后不重复轰炸（2.2.9）

function Convert-NetDayNode($node) {
    $h = @{}
    if ($null -eq $node) { return $h }
    foreach ($p in $node.PSObject.Properties) {
        try { $idx = [int]$p.Name } catch { continue }
        $r = 0.0; $s = 0.0
        try { $r = [double]$p.Value.r } catch { }
        try { $s = [double]$p.Value.s } catch { }
        $h[$idx] = @{ r = $r; s = $s }
    }
    return $h
}

# 保留天数（2.2.9 · 批次 C）：配置 netKeepDays 是唯一来源；缺键 / 越界一律回落 400。
function Get-NetKeepDays {
    $n = 0
    try { $n = [int]$script:Cfg.netKeepDays } catch { }
    if ($n -lt 30 -or $n -gt 3650) { $n = 400 }
    return $n
}

# 改小保留天数时立即裁剪并回写，不等下次启动（否则旧数据会继续留在盘上）。
function Set-NetRetention([int]$Days) {
    if ($Days -lt 30 -or $Days -gt 3650) { return }
    $script:NetKeepDays = $Days
    if (-not $script:NetLoaded -or -not $script:NetDaysPath) { return }
    try {
        $cutoff = (Get-Date).AddDays(-$Days).ToString('yyyy-MM-dd')
        $removed = 0
        foreach ($k in @($script:NetDays.Keys)) {
            if ($k -lt $cutoff) { [void]$script:NetDays.Remove($k); $removed++ }
        }
        if ($removed -gt 0) { Save-NetDays }
    } catch {
        Write-AppLog ('网络历史裁剪失败: ' + $_.Exception.Message) 'WARN'
    }
}

# 告警状态落盘（2.2.9）：重启后同一天 / 同一月不重复提醒；只保留今天的按接口记录。
function Save-NetAlertState {
    if (-not $script:NetAlertStatePath) { return }
    try {
        $todayKey = (Get-Date).ToString('yyyy-MM-dd')
        $ifs = [ordered]@{}
        foreach ($k in @($script:NetAlertedIf.Keys)) {
            if ($k.StartsWith($todayKey + '|')) { $ifs[[string]$k] = $true }
        }
        $doc = [ordered]@{ day = $script:NetAlertedDay; month = $script:NetAlertedMonth; ifs = $ifs }
        $json = $doc | ConvertTo-Json -Depth 3 -Compress
        $tmp = $script:NetAlertStatePath + '.tmp'
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $script:NetAlertStatePath -Force
    } catch {
        Write-AppLog ('告警状态落盘失败: ' + $_.Exception.Message) 'WARN'
    }
}

# 手动清除提醒记录：达到阈值会重新提醒（不会改阈值本身）。
function Reset-NetAlertState {
    $script:NetAlertedDay = ''
    $script:NetAlertedMonth = ''
    $script:NetAlertedIf = @{}
    Save-NetAlertState
}

# 某接口某天的累计（已落盘 + 今天未落盘的增量）；接口名对不上返回 $null。
function Get-NetIfDaySum([string]$IfName, [string]$DayKey) {
    $idx = -1
    foreach ($k in $script:NetMeta.Keys) {
        if ([string]$script:NetMeta[$k].name -eq $IfName) { $idx = [int]$k; break }
    }
    if ($idx -lt 0) { return $null }
    $r = 0.0; $s = 0.0
    if ($script:NetDays.ContainsKey($DayKey) -and $script:NetDays[$DayKey].ContainsKey($idx)) {
        $r += [double]$script:NetDays[$DayKey][$idx].r
        $s += [double]$script:NetDays[$DayKey][$idx].s
    }
    if ($DayKey -eq $script:NetDayKey -and $script:NetDayAcc.ContainsKey($idx)) {
        $r += [double]$script:NetDayAcc[$idx].r
        $s += [double]$script:NetDayAcc[$idx].s
    }
    return @{ recv = [math]::Round($r, 0); sent = [math]::Round($s, 0) }
}

function Initialize-NetPersistence {
    if ($script:NetLoaded) { return }
    $script:NetLoaded = $true
    $script:NetTrafficDir = Join-Path $script:DataDir 'traffic'
    $script:NetDaysPath = Join-Path $script:NetTrafficDir 'days.json'
    $script:NetAlertStatePath = Join-Path $script:NetTrafficDir 'alert-state.json'
    try {
        if (-not (Test-Path -LiteralPath $script:NetTrafficDir)) {
            New-Item -ItemType Directory -Path $script:NetTrafficDir -Force | Out-Null
        }
    } catch { }
    try {
        if (Test-Path -LiteralPath $script:NetDaysPath) {
            $doc = Get-Content -LiteralPath $script:NetDaysPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $doc.PSObject.Properties) {
                if ($p.Name -eq '__meta') {
                    foreach ($mp in $p.Value.PSObject.Properties) {
                        try {
                            $script:NetMeta[[int]$mp.Name] = @{
                                name = [string]$mp.Value.name
                                kind = [string]$mp.Value.kind
                            }
                        } catch { }
                    }
                    continue
                }
                $script:NetDays[$p.Name] = Convert-NetDayNode $p.Value
            }
        }
    } catch {
        # 坏文件不阻塞启动：当作空历史，落盘时会被新数据整体替换
        Write-AppLog ('网络历史读取失败，按空历史处理: ' + $_.Exception.Message) 'WARN'
        $script:NetDays = @{}
    }
    $script:NetDayKey = (Get-Date).ToString('yyyy-MM-dd')
    # 告警状态（2.2.9）：坏文件当没提醒过——宁可多提醒一次，也不要永远不提醒
    try {
        if ($script:NetAlertStatePath -and (Test-Path -LiteralPath $script:NetAlertStatePath)) {
            $st = Get-Content -LiteralPath $script:NetAlertStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($st.day) { $script:NetAlertedDay = [string]$st.day }
            if ($st.month) { $script:NetAlertedMonth = [string]$st.month }
            if ($st.ifs) {
                foreach ($p in $st.ifs.PSObject.Properties) {
                    if ([bool]$p.Value) { $script:NetAlertedIf[[string]$p.Name] = $true }
                }
            }
        }
    } catch {
        Write-AppLog ('告警状态读取失败，按未提醒处理: ' + $_.Exception.Message) 'WARN'
    }
    # 过期清理：只保留配置的保留天数（默认 400）
    try {
        $keep = Get-NetKeepDays
        $script:NetKeepDays = $keep
        $cutoff = (Get-Date).AddDays(-$keep).ToString('yyyy-MM-dd')
        foreach ($k in @($script:NetDays.Keys)) {
            if ($k -lt $cutoff) { [void]$script:NetDays.Remove($k) }
        }
    } catch { }
}

function Add-NetSampleToAccum($sample) {
    if (-not $sample -or -not $sample.ifs) { return }
    $dayKey = (Get-Date).ToString('yyyy-MM-dd')
    if ($script:NetDayKey -ne $dayKey) {
        # 跨日：先把旧的一天落稳，再开新账本
        try { Flush-NetStats } catch { }
        $script:NetDayKey = $dayKey
    }
    foreach ($ifi in $sample.ifs) {
        $idx = 0
        try { $idx = [int]$ifi.ifIndex } catch { continue }
        if ($idx -le 1) { continue }
        try { $script:NetMeta[$idx] = @{ name = [string]$ifi.name; kind = [string]$ifi.kind } } catch { }
        if ($null -eq $ifi.recvTotal -and $null -eq $ifi.sentTotal) { continue }
        $r = 0.0; $s = 0.0
        try { if ($null -ne $ifi.recvTotal) { $r = [double]$ifi.recvTotal } } catch { }
        try { if ($null -ne $ifi.sentTotal) { $s = [double]$ifi.sentTotal } } catch { }
        $last = if ($script:NetLastTotals.ContainsKey($idx)) { $script:NetLastTotals[$idx] } else { $null }
        if ($last) {
            $dr = $r - [double]$last.r
            $ds = $s - [double]$last.s
            if ($dr -ge 0 -and $ds -ge 0 -and ($dr -gt 0 -or $ds -gt 0)) {
                if (-not $script:NetDayAcc.ContainsKey($idx)) {
                    $script:NetDayAcc[$idx] = @{ r = 0.0; s = 0.0 }
                }
                $script:NetDayAcc[$idx].r += $dr
                $script:NetDayAcc[$idx].s += $ds
            }
            # 计数器回退：不累计，基线随新值走
        }
        $script:NetLastTotals[$idx] = @{ r = $r; s = $s }
    }
}

function Merge-NetAccIntoDays {
    if ($script:NetDayAcc.Count -eq 0) { return }
    if (-not $script:NetDays.ContainsKey($script:NetDayKey)) {
        $script:NetDays[$script:NetDayKey] = @{}
    }
    $day = $script:NetDays[$script:NetDayKey]
    foreach ($idx in $script:NetDayAcc.Keys) {
        $a = $script:NetDayAcc[$idx]
        if (-not $day.ContainsKey($idx)) { $day[$idx] = @{ r = 0.0; s = 0.0 } }
        $day[$idx].r += [double]$a.r
        $day[$idx].s += [double]$a.s
    }
    $script:NetDayAcc = @{}
}

function Save-NetDays {
    if (-not $script:NetDaysPath) { return }
    try {
        $doc = [ordered]@{}
        $metaOut = [ordered]@{}
        foreach ($idx in $script:NetMeta.Keys) {
            $metaOut[[string]$idx] = @{ name = $script:NetMeta[$idx].name; kind = $script:NetMeta[$idx].kind }
        }
        $doc['__meta'] = $metaOut
        foreach ($k in ($script:NetDays.Keys | Sort-Object)) {
            $node = [ordered]@{}
            foreach ($idx in $script:NetDays[$k].Keys) {
                $node[[string]$idx] = @{ r = [math]::Round([double]$script:NetDays[$k][$idx].r, 0); s = [math]::Round([double]$script:NetDays[$k][$idx].s, 0) }
            }
            $doc[$k] = $node
        }
        $json = $doc | ConvertTo-Json -Depth 6 -Compress
        $tmp = $script:NetDaysPath + '.tmp'
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $script:NetDaysPath -Force
    } catch {
        Write-AppLog ('网络历史落盘失败: ' + $_.Exception.Message) 'WARN'
    }
}

function Flush-NetStats {
    Merge-NetAccIntoDays
    Save-NetDays
    $script:NetLastFlush = Get-Date
}

# ---------- 汇总快照（下发界面） ----------
function Get-NetDaySum([string]$DayKey) {
    # 注意：PowerShell 变量名大小写不敏感——参数与局部变量不能用 $Day/$day 这种只差大小写的组合，
    # 否则赋值会覆盖参数本身（2.2.1 自检抓出的真实 bug：今日/本月永远算出 0）。
    $r = 0.0; $s = 0.0
    $dayNode = $script:NetDays[$DayKey]
    if ($dayNode) {
        foreach ($idx in $dayNode.Keys) {
            $kind = if ($script:NetMeta.ContainsKey($idx)) { $script:NetMeta[$idx].kind } else { 'other' }
            if ($kind -ne 'wifi' -and $kind -ne 'ethernet') { continue }
            $r += [double]$dayNode[$idx].r
            $s += [double]$dayNode[$idx].s
        }
    }
    if ($DayKey -eq $script:NetDayKey -and $script:NetDayAcc.Count -gt 0) {
        foreach ($idx in $script:NetDayAcc.Keys) {
            $kind = if ($script:NetMeta.ContainsKey($idx)) { $script:NetMeta[$idx].kind } else { 'other' }
            if ($kind -ne 'wifi' -and $kind -ne 'ethernet') { continue }
            $r += [double]$script:NetDayAcc[$idx].r
            $s += [double]$script:NetDayAcc[$idx].s
        }
    }
    return @{ recv = [math]::Round($r, 0); sent = [math]::Round($s, 0) }
}

function Get-NetTotalsSnapshot {
    $today = Get-NetDaySum $script:NetDayKey
    $monthKey = (Get-Date).ToString('yyyy-MM')
    $mr = 0.0; $ms = 0.0
    foreach ($k in $script:NetDays.Keys) {
        if (-not $k.StartsWith($monthKey)) { continue }
        $d = Get-NetDaySum $k
        $mr += [double]$d.recv
        $ms += [double]$d.sent
    }
    $month = @{ recv = [math]::Round($mr, 0); sent = [math]::Round($ms, 0) }
    # 近 30 天（含今天未完的这一天）与近 12 个月；今天/本月已含未落盘增量
    $daysArr = New-Object System.Collections.Generic.List[object]
    for ($i = 29; $i -ge 0; $i--) {
        $d = (Get-Date).Date.AddDays(-$i).ToString('yyyy-MM-dd')
        $sum = Get-NetDaySum $d
        [void]$daysArr.Add(@{ d = $d; recv = $sum.recv; sent = $sum.sent })
    }
    $monthsArr = New-Object System.Collections.Generic.List[object]
    $base = Get-Date -Day 1
    for ($i = 11; $i -ge 0; $i--) {
        $m = $base.AddMonths(-$i).ToString('yyyy-MM')
        $mr2 = 0.0; $ms2 = 0.0
        foreach ($k in $script:NetDays.Keys) {
            if (-not $k.StartsWith($m)) { continue }
            $d2 = Get-NetDaySum $k
            $mr2 += [double]$d2.recv
            $ms2 += [double]$d2.sent
        }
        [void]$monthsArr.Add(@{ m = $m; recv = [math]::Round($mr2, 0); sent = [math]::Round($ms2, 0) })
    }
    # 按接口日明细（近 30 天，含今天未落盘增量）：历史导出用（2.2.8 批次 B）。
    # 结构 date -> ifIndex -> {r,s}，与 days.json 的日节点同构；只输出有数据的日期，体积恒小。
    $ifDays = [ordered]@{}
    for ($i = 29; $i -ge 0; $i--) {
        $dk = (Get-Date).Date.AddDays(-$i).ToString('yyyy-MM-dd')
        $node = [ordered]@{}
        if ($script:NetDays.ContainsKey($dk)) {
            foreach ($idx in $script:NetDays[$dk].Keys) {
                $node[[string]$idx] = @{
                    r = [math]::Round([double]$script:NetDays[$dk][$idx].r, 0)
                    s = [math]::Round([double]$script:NetDays[$dk][$idx].s, 0)
                }
            }
        }
        if ($dk -eq $script:NetDayKey -and $script:NetDayAcc.Count -gt 0) {
            foreach ($idx in $script:NetDayAcc.Keys) {
                $k2 = [string]$idx
                $accR = [math]::Round([double]$script:NetDayAcc[$idx].r, 0)
                $accS = [math]::Round([double]$script:NetDayAcc[$idx].s, 0)
                if ($node.Contains($k2)) {
                    $node[$k2] = @{ r = [double]$node[$k2].r + $accR; s = [double]$node[$k2].s + $accS }
                } else {
                    $node[$k2] = @{ r = $accR; s = $accS }
                }
            }
        }
        if ($node.Count -gt 0) { $ifDays[$dk] = $node }
    }
    $metaOut = [ordered]@{}
    foreach ($idx in $script:NetMeta.Keys) {
        $metaOut[[string]$idx] = @{ name = $script:NetMeta[$idx].name; kind = $script:NetMeta[$idx].kind }
    }
    return @{
        today = $today
        month = $month
        days  = $daysArr
        months= $monthsArr
        ifDays= $ifDays
        meta  = $metaOut
    }
}

function Send-NetTotals {
    Send-ToUi @{ type = 'netTotals'; totals = (Get-NetTotalsSnapshot) }
}

# ---------- 浮窗 / 托盘用的速率快照 ----------
# 物理接口合计；超过 5 秒没更新就视为失效（返回 $null → 界面显示 N/A，不拿旧数冒充实时）
function Get-NetUiRates {
    $u = $script:NetUiRates
    if (-not $u -or -not $u.at) { return $null }
    try { if (((Get-Date) - $u.at).TotalSeconds -gt 5) { return $null } } catch { }
    return @{ recv = [double]$u.recv; sent = [double]$u.sent }
}

function Update-NetUiRatesFromSample($sample) {
    if (-not $sample -or -not $sample.ifs) { return }
    $rr = 0.0; $ss = 0.0; $any = $false
    foreach ($ifi in $sample.ifs) {
        $idx = 0
        try { $idx = [int]$ifi.ifIndex } catch { }
        $kind = if ($script:NetMeta.ContainsKey($idx)) { [string]$script:NetMeta[$idx].kind } else { [string]$ifi.kind }
        if ($kind -ne 'wifi' -and $kind -ne 'ethernet') { continue }
        if ($null -ne $ifi.recvBps) { $rr += [double]$ifi.recvBps; $any = $true }
        if ($null -ne $ifi.sentBps) { $ss += [double]$ifi.sentBps }
    }
    if (-not $any) { return }
    $script:NetUiRates = @{ recv = $rr; sent = $ss; at = Get-Date }
    Update-NetTray $rr $ss
}

# ---------- 托盘图标 ----------
function Format-NetRateText([double]$Bps) {
    if ($Bps -ge 1MB) { return ('{0:0.0} MB/s' -f ($Bps / 1MB)) }
    if ($Bps -ge 1KB) { return ('{0:0.0} KB/s' -f ($Bps / 1KB)) }
    return ('{0:0} B/s' -f $Bps)
}

# ---------- 收起 / 还原（2.2.3）----------
# 隐藏用 PcTrayWindow（定义在 90-Main：网络采样器禁止出现 Add-Type）。
# 不能用 Form.ShowInTaskbar：改它就会重建窗口句柄，还原时「窗口闪一下又消失」。
$script:TrayHidden = $false
$script:TrayHomeLocation = $null
$script:TrayHomeState = 'Normal'
$script:TrayRestoreAt = [datetime]::MinValue

# 从托盘还原主窗口（左键单击 / 双击 / 右键菜单共用）。
# 400ms 去抖：双击会触发两次单击 + 一次双击，不能让同一次还原跑三遍。
function Restore-PerfWindowFromTray {
    try {
        $f = $script:MainForm
        if (-not $f) { return }
        $now = Get-Date
        if (($now - $script:TrayRestoreAt).TotalMilliseconds -lt 400) { return }
        $script:TrayRestoreAt = $now
        if ($script:TrayHidden -and (Ensure-PcTrayWindow)) {
            $loc = $script:TrayHomeLocation
            if (-not $loc) { $loc = New-Object System.Drawing.Point(120, 80) }
            [PcTrayWindow]::Show($f.Handle, $loc.X, $loc.Y)
            $f.Opacity = 1
            $script:TrayHidden = $false
            Write-AppLog '窗口已从托盘还原'
        }
        $f.Show()
        $f.WindowState = if ($script:TrayHomeState -eq 'Maximized') { 'Maximized' } else { 'Normal' }
        $f.Activate()
        try { $f.TopMost = $true; $f.TopMost = $false } catch { }
        if (Get-Command Register-PerfHotkeys -ErrorAction SilentlyContinue) {
            try { [void](Register-PerfHotkeys) } catch { }
        }
    } catch { }
}

function Initialize-NetTray {
    if ($script:NetTray) { return }
    try {
        $tray = New-Object System.Windows.Forms.NotifyIcon
        $tray.Visible = $true
        try {
            $ico = Join-Path $script:Root 'assets\app-icon.ico'
            if (Test-Path $ico) { $tray.Icon = New-Object System.Drawing.Icon($ico) }
        } catch { }
        $tray.Text = 'PerfCapture'
        # 右键菜单：收起后这是唯一可见入口，必须能还原与真正退出
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $miShow = New-Object System.Windows.Forms.ToolStripMenuItem('显示主界面')
        $miShow.Add_Click({ Restore-PerfWindowFromTray })
        [void]$menu.Items.Add($miShow)
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $miExit = New-Object System.Windows.Forms.ToolStripMenuItem('退出')
        $miExit.Add_Click({
            $script:ForceExit = $true
            try { if ($script:MainForm) { $script:MainForm.Close() } } catch { }
        })
        [void]$menu.Items.Add($miExit)
        $tray.ContextMenuStrip = $menu
        $tray.Add_MouseClick({
            param($s, $e)
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                Restore-PerfWindowFromTray
            }
        })
        # 双击是用户最常用的还原手势，单独挂一次；400ms 去抖会吞掉重复触发
        $tray.Add_MouseDoubleClick({
            param($s, $e)
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                Restore-PerfWindowFromTray
            }
        })
        $script:NetTray = $tray
    } catch {
        Write-AppLog ('托盘图标创建失败: ' + $_.Exception.Message) 'WARN'
        $script:NetTray = $null
    }
}

function Update-NetTray([double]$Recv, [double]$Sent) {
    if (-not $script:NetTray) { return }
    try {
        $txt = 'PerfCapture · ↓' + (Format-NetRateText $Recv) + ' ↑' + (Format-NetRateText $Sent)
        if ($script:NetTray.Text -ne $txt) { $script:NetTray.Text = $txt }
    } catch { }
}

function Remove-NetTray {
    if (-not $script:NetTray) { return }
    try { $script:NetTray.Visible = $false; $script:NetTray.Dispose() } catch { }
    $script:NetTray = $null
}

# ---------- 阈值告警 ----------
# 今日/本月（物理接口，收+发）达到配置阈值时提醒；每日/每月各最多一次，重开程序不重复轰炸
function Show-NetAlert([string]$Text) {
    Write-AppLog ('网络流量告警: ' + $Text) 'WARN'
    try {
        if ($script:NetTray) {
            $script:NetTray.BalloonTipTitle = 'PerfCapture · 流量提醒'
            $script:NetTray.BalloonTipText = $Text
            $script:NetTray.ShowBalloonTip(10000)
        }
    } catch { }
    try { if (Get-Command Flash-PerfTaskbar -ErrorAction SilentlyContinue) { Flash-PerfTaskbar } } catch { }
}

function Invoke-NetAlertCheck {
    $dayMB = 0; $monMB = 0
    try { $dayMB = [int]$script:Cfg.netAlertDayMB } catch { }
    try { $monMB = [int]$script:Cfg.netAlertMonthMB } catch { }
    $ifCfg = $null
    try { $ifCfg = $script:Cfg.netAlertIfMB } catch { }
    $hasIf = ($ifCfg -and $ifCfg.Keys -and @($ifCfg.Keys).Count -gt 0)
    if ($dayMB -le 0 -and $monMB -le 0 -and -not $hasIf) { return }
    $dayKey = (Get-Date).ToString('yyyy-MM-dd')
    $monKey = (Get-Date).ToString('yyyy-MM')
    $dirty = $false
    if ($dayMB -gt 0 -and $script:NetAlertedDay -ne $dayKey) {
        $today = Get-NetDaySum $script:NetDayKey
        if ([double]$today.recv + [double]$today.sent -ge ($dayMB * 1MB)) {
            $script:NetAlertedDay = $dayKey
            $dirty = $true
            Show-NetAlert ('今日流量已达 ' + $dayMB + ' MB，注意用量')
        }
    }
    if ($monMB -gt 0 -and $script:NetAlertedMonth -ne $monKey) {
        $mr = 0.0; $ms = 0.0
        foreach ($k in $script:NetDays.Keys) {
            if (-not $k.StartsWith($monKey)) { continue }
            $d = Get-NetDaySum $k
            $mr += [double]$d.recv; $ms += [double]$d.sent
        }
        if ([math]::Round($mr + $ms, 0) -ge ($monMB * 1MB)) {
            $script:NetAlertedMonth = $monKey
            $dirty = $true
            Show-NetAlert ('本月流量已达 ' + $monMB + ' MB，注意用量')
        }
    }
    # 按接口每日阈值（2.2.9）：接口名 → MB；0 / 未配置 = 不单独提醒；每接口每天最多一次
    if ($hasIf) {
        foreach ($ifName in @($ifCfg.Keys)) {
            $mb = 0
            try { $mb = [int]$ifCfg[$ifName] } catch { }
            if ($mb -le 0) { continue }
            $ack = $dayKey + '|' + [string]$ifName
            if ($script:NetAlertedIf.ContainsKey($ack)) { continue }
            $sum = Get-NetIfDaySum ([string]$ifName) $dayKey
            if (-not $sum) { continue }
            if (([double]$sum.recv + [double]$sum.sent) -ge ($mb * 1MB)) {
                $script:NetAlertedIf[$ack] = $true
                $dirty = $true
                Show-NetAlert ('接口「' + $ifName + '」今日流量已达 ' + $mb + ' MB，注意用量')
            }
        }
    }
    # 提醒记录落盘：重启后不重复轰炸（手动清除 / 跨日跨月才复位）
    if ($dirty) { Save-NetAlertState }
}

# ---------- 能力表与采样调度 ----------
function Build-NetCaps {
    $script:NetCaps = @{
        net       = $false      # 首个真实样本到达后置 true（Update-NetCapsFromSample）
        running   = $script:NetRunning
        intervalMs= $script:NetIntervalMs
        ringSize  = $script:NetRingSize
        persist   = $script:NetConsumers.ContainsKey('persist')
    }
    return $script:NetCaps
}

function Update-NetCapsFromSample($s) {
    if (-not $script:NetCaps) { Build-NetCaps }
    if ($s -and $s.ifs -and @($s.ifs).Count -gt 0) { $script:NetCaps.net = $true }
}

function Start-NetWorker {
    # 常驻 runspace：网络采样无 C# 编译，同样只创建一次，重启不清基线
    if ($script:NetWorker) { return }
    try {
        if (-not $script:NetQueue) {
            $script:NetQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        }
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($script:NetSampleScript)
        [void]$ps.AddParameter('Queue', $script:NetQueue)
        if (-not $script:NetCtl) { $script:NetCtl = @{ stop = $false } }
        $script:NetCtl.stop = $false
        $script:NetCtl.reverseDns = [bool]$script:NetReverseDnsWant
        [void]$ps.AddParameter('Ctl', $script:NetCtl)
        $handle = $ps.BeginInvoke()
        $script:NetWorker = @{ PS = $ps; Handle = $handle }
        Write-AppLog '网络采样 runspace 已启动'
    } catch {
        Write-AppLog ('网络采样启动失败: ' + $_.Exception.Message) 'ERROR'
        $script:NetWorker = $null
    }
}

function Stop-NetWorker {
    if (-not $script:NetWorker) { return }
    try {
        if ($script:NetCtl) { $script:NetCtl.stop = $true }
        $w = $script:NetWorker
        # 常规情况下循环在 100ms 内看到 stop 标志；1.2 秒是保护上限（采样偶尔卡在 WMI 调用里）
        $deadline = (Get-Date).AddSeconds(1.2)
        while (-not $w.Handle.IsCompleted -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
        if (-not $w.Handle.IsCompleted) { try { $w.PS.Stop() } catch { } }
        try { [void]$w.PS.EndInvoke($w.Handle) } catch { }
        try { $w.PS.Dispose() } catch { }
        Write-AppLog '网络采样 runspace 已停止'
    } catch { }
    $script:NetWorker = $null
    # 排空队列，避免下次启动时冒出旧数据
    try {
        $dummy = $null
        while ($script:NetQueue.TryDequeue([ref]$dummy)) { }
    } catch { }
}

# ---------- 宿主计时器：取队列 → 累计/环形缓冲 → 按需推给界面 ----------
function Invoke-NetTick {
    if (-not $script:NetQueue) { return }
    $wantUi = $script:NetConsumers.ContainsKey('page')
    $got = $false
    try {
        $raw = $null
        while ($script:NetQueue.TryDequeue([ref]$raw)) {
            $got = $true
            $sample = $null
            try { $sample = $raw | ConvertFrom-Json } catch { continue }
            Add-NetSampleToAccum $sample
            Update-NetUiRatesFromSample $sample
            if (-not $script:NetTray) { Initialize-NetTray }
            [void]$script:NetSamples.Add($sample)
            if ($script:NetSamples.Count -gt $script:NetRingSize) {
                [void]$script:NetSamples.RemoveAt(0)
            }
            Update-NetCapsFromSample $sample
            if ($wantUi) { Send-ToUi @{ type = 'netSample'; sample = $sample; caps = $script:NetCaps } }
        }
    } catch {
        Write-AppLog ('网络采样分发失败: ' + $_.Exception.Message) 'WARN'
    }
    if ($got -and -not $script:NetRunning) {
        $script:NetRunning = $true
        if ($wantUi) { Send-NetCaps }
    }
    # 持久化：内存累加，每 FlushSec 秒落盘一次（有增量才写）；落盘后顺手做一次阈值告警检查
    try {
        if ($script:NetDayAcc.Count -gt 0 -and
            ($null -eq $script:NetLastFlush -or ((Get-Date) - $script:NetLastFlush).TotalSeconds -ge $script:NetFlushSec)) {
            Flush-NetStats
            Invoke-NetAlertCheck
            if ($wantUi) { Send-NetTotals }
        }
    } catch { }
}

function Send-NetCaps {
    if (-not $script:NetCaps) { Build-NetCaps }
    $script:NetCaps.running = $script:NetRunning
    Send-ToUi @{ type = 'netCaps'; caps = $script:NetCaps }
}

function Start-NetSampler {
    if ($script:NetTimer) { return }
    Initialize-NetPersistence
    Start-NetWorker
    $script:NetTimer = New-Object System.Windows.Forms.Timer
    $script:NetTimer.Interval = 250
    $script:NetTimer.Add_Tick({ Invoke-NetTick })
    $script:NetTimer.Start()
}

function Stop-NetSampler {
    if ($script:NetTimer) {
        try { $script:NetTimer.Stop(); $script:NetTimer.Dispose() } catch { }
        $script:NetTimer = $null
    }
    Stop-NetWorker
    if ($script:NetRunning) {
        $script:NetRunning = $false
        if ($script:NetConsumers.ContainsKey('page')) { Send-NetCaps }
    }
}

# 消费者门控：persist 常驻（程序在跑就累计），page 只决定要不要往界面推
function Set-NetConsumer([string]$Key, [bool]$On) {
    if (-not $Key) { return }
    if ($On) {
        $script:NetConsumers[$Key] = $true
        if (-not $script:NetTimer) { Start-NetSampler }
        if ($Key -eq 'page') {
            Send-NetCaps
            Send-NetTotals
        }
    } else {
        [void]$script:NetConsumers.Remove($Key)
        if ($script:NetConsumers.Count -eq 0) { Stop-NetSampler }
    }
}

# ---------- 退出落盘（90-Main FormClosing 调用） ----------
# 反向 DNS 开关（默认关）：设置保存时由 Set-ConfigValue 调用，运行中即时生效
function Set-NetReverseDns([bool]$On) {
    $script:NetReverseDnsWant = $On
    if ($script:NetCtl) { $script:NetCtl.reverseDns = $On }
}

function Flush-NetStatsOnExit {
    try { Flush-NetStats } catch { }
    Remove-NetTray
    Stop-NetSampler
}

# ---------- 桥接命令（ui→host） ----------
function Invoke-NetCommand($msg) {
    switch ($msg.cmd) {
        'netStart' { Set-NetConsumer 'page' $true }
        'netStop'  { Set-NetConsumer 'page' $false }
        default { Write-AppLog ('未知网络命令: ' + $msg.cmd) 'WARN' }
    }
}
