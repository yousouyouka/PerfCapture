# 网络实时采样器（2.1.18 · 流量监控阶段 1）
#
# 设计要点（流量监控功能规划 v2 §1.1 / §1.8）：
#   - L1 接口总量口径：每 1 秒对每块非隐藏网卡做 Get-NetAdapterStatistics 差分。
#   - 常驻监控与游戏采集完全解耦：绝不启动 PresentMon / logman / 任何 ETW 会话，不编译 C#，
#     不需要管理员权限。独立于 35-Metrics 的采样器（那台开机会拉起 PresentMon 突发窗口）。
#   - 常驻 runspace 循环采样 → ConcurrentQueue 回传 → 宿主计时器取走（复用 35-Metrics 样板）。
#   - 采不到的一律 $null（不是 0）：界面显示「—」，绝不假装有数据。
#   - 计数器回退（网卡重连 / 驱动重置）→ 该秒速率置 null 并重置基线，绝不报负数。
#   - 首秒只记基线不出速率：没有时间基准就不造数。

$script:NetIntervalMs = 1000
$script:NetRingSize = 120        # 1 Hz × 120 点 ≈ 2 分钟窗口
$script:NetSamples = New-Object System.Collections.ArrayList
$script:NetWorker = $null
$script:NetQueue = $null
$script:NetTimer = $null
$script:NetRunning = $false
$script:NetConsumers = @{}       # 谁在要数据：page（网络页）/ 以后 overlay
$script:NetCaps = $null

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
$prev = @{}
$wall = $null
$tick = 0
while ($true) {
    if ($Ctl -and $Ctl.stop) { break }
    try {
        $tick++
        # 元数据（Virtual / MediaType / Status / 链路速度）变化极慢，每 5 秒刷一次就够
        if (($tick % 5) -eq 1 -or $meta.Count -eq 0) {
            $meta = @{}
            foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue)) {
                try { $meta[[int]$a.InterfaceIndex] = $a } catch { }
            }
        }
        $now = Get-Date
        $seen = @{}
        $ifs = New-Object System.Collections.Generic.List[object]
        foreach ($s in @(Get-NetAdapterStatistics -ErrorAction SilentlyContinue)) {
            $idx = 0
            try { $idx = [int]$s.ifIndex } catch { }
            if ($idx -eq 0) { try { $idx = [int]$s.InterfaceIndex } catch { } }
            if ($idx -le 1) { continue }          # 0 = 非法；1 = Loopback，不计
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
            $ifs.Add([ordered]@{
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
            })
        }
        foreach ($gone in @($prev.Keys | Where-Object { -not $seen.ContainsKey($_) })) { [void]$prev.Remove($gone) }
        $wall = $now
        [void]$Queue.Enqueue(@{
            at  = $now.ToString('yyyy-MM-dd HH:mm:ss')
            ifs = $ifs
        })
    } catch {
        # 任何一次异常都不许弄死采样线程：丢这一秒，下秒重来
    }
    Start-Sleep -Milliseconds 1000
}
'@

function Build-NetCaps {
    $script:NetCaps = @{
        net       = $false      # 首个真实样本到达后置 true（Update-NetCapsFromSample）
        running   = $script:NetRunning
        intervalMs= $script:NetIntervalMs
        ringSize  = $script:NetRingSize
    }
    return $script:NetCaps
}

function Update-NetCapsFromSample($s) {
    if (-not $script:NetCaps) { Build-NetCaps }
    if ($s -and $s.ifs -and @($s.ifs).Count -gt 0) { $script:NetCaps.net = $true }
}

# ---------- 采样调度 ----------
function Start-NetWorker {
    # 常驻 runspace：网络采样虽无 C# 编译，同样只创建一次，重启不清基线
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
        $deadline = (Get-Date).AddSeconds(2.5)
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

# ---------- 宿主计时器：取队列 → 环形缓冲 → 推给界面 ----------
function Invoke-NetTick {
    if (-not $script:NetQueue) { return }
    $got = $false
    try {
        $sample = $null
        while ($script:NetQueue.TryDequeue([ref]$sample)) {
            $got = $true
            [void]$script:NetSamples.Add($sample)
            if ($script:NetSamples.Count -gt $script:NetRingSize) {
                [void]$script:NetSamples.RemoveAt(0)
            }
            Update-NetCapsFromSample $sample
            Send-ToUi @{ type = 'netSample'; sample = $sample; caps = $script:NetCaps }
        }
    } catch {
        Write-AppLog ('网络采样分发失败: ' + $_.Exception.Message) 'WARN'
    }
    if ($got -and -not $script:NetRunning) {
        $script:NetRunning = $true
        Send-NetCaps
    }
}

function Send-NetCaps {
    if (-not $script:NetCaps) { Build-NetCaps }
    $script:NetCaps.running = $script:NetRunning
    Send-ToUi @{ type = 'netCaps'; caps = $script:NetCaps }
}

function Start-NetSampler {
    if ($script:NetTimer) { return }
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
        Send-NetCaps
    }
}

# 消费者门控：与 35-Metrics 同一思路——没人要数据就整组停（采样 + 计时器都停）
function Set-NetConsumer([string]$Key, [bool]$On) {
    if (-not $Key) { return }
    if ($On) {
        $script:NetConsumers[$Key] = $true
        if (-not $script:NetTimer) { Start-NetSampler }
    } else {
        [void]$script:NetConsumers.Remove($Key)
        if ($script:NetConsumers.Count -eq 0) { Stop-NetSampler }
    }
}

# ---------- 桥接命令（ui→host） ----------
function Invoke-NetCommand($msg) {
    switch ($msg.cmd) {
        'netStart' { Set-NetConsumer 'page' $true }
        'netStop'  { Set-NetConsumer 'page' $false }
        default { Write-AppLog ('未知网络命令: ' + $msg.cmd) 'WARN' }
    }
}
