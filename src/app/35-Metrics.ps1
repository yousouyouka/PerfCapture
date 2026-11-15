# 实时监控采样器（1.5.0 · 批次 A）
#
# 设计要点：
#   - 只读遥测，**零注入**：nvidia-smi 取 GPU，Win32 P/Invoke 取 CPU/内存；不碰游戏进程、不装驱动。
#   - 一轮采样跑在 runspace 里，宿主用 WinForms Timer 轮询结果，UI 线程不阻塞。
#   - 环形缓冲只放内存（默认 120 点 = 2 分钟 @1 Hz），采样结束不落盘。
#   - 采不到的字段一律 $null（不是 0）：界面显示「—」，绝不假装有数据。
#   - CPU 温度 / CPU 风扇 / 主板·硬盘温度**本轮不做**：Windows 无可靠无驱动通道。
#     能力表里保留 cpuTemp / cpuFan / diskTemp 三个位置（恒为 $false），
#     以后若做「可选传感器组件」，由用户显式安装后才置 $true。
#
# 为什么不用 Get-Counter / CIM：
#   - Get-Counter 的计数器路径在中文系统是本地化的，硬编码英文路径直接失败；
#   - CIM（Win32_PerfFormattedData_*）语言无关，但每轮 3 个类约 700 ms，1 Hz 下太贵。
#   所以主路径用 P/Invoke：GetSystemTimes（CPU%）、GlobalMemoryStatusEx（内存）、
#   CallNtPowerInformation（有效频率）都 <1 ms，且与系统语言无关；CIM 只作兜底。

$script:MetricsIntervalMs = 1000
$script:MetricsRingSize = 120
$script:MetricsSamples = New-Object System.Collections.ArrayList
$script:MetricsCaps = $null
$script:MetricsWorker = $null
$script:MetricsQueue = $null
$script:MetricsTimer = $null
$script:MetricsRunning = $false
$script:MetricsConsumers = @{}   # 谁在要数据：page（实时监控页）/ overlay（浮窗）
$script:MetricsSmiPath = ''
$script:MetricsCpuBaseMhz = 0

# ---------- 一轮采样（runspace 里执行；单引号 here-string，禁止变量展开） ----------
$script:MetricsSampleScript = @'
param($SmiPath, $Queue, $IntervalMs, $Ctl)
while ($true) {
    if ($Ctl -and $Ctl.stop) { break }
$out = [ordered]@{
    at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    cpu = $null; cpuMhz = $null; cpuMhzMax = $null
    gpu = $null; gpuClock = $null; gpuMemClock = $null; gpuTemp = $null; gpuPower = $null; gpuFan = $null
    vramUsed = $null; vramTotal = $null
    ramUsed = $null; ramTotal = $null
}
function ToNum($v) {
    if ($null -eq $v) { return $null }
    $s = ([string]$v).Trim()
    if (-not $s) { return $null }
    if ($s -match 'N/A|Not Supported|Unknown|^\[.*\]$') { return $null }
    $d = 0.0
    if ([double]::TryParse($s, [ref]$d)) { return $d }
    return $null
}

# ---- 原生采集器（进程内编译一次，之后所有轮次复用）----
if (-not ('PcMetrics' -as [type])) {
    $cs = @(
        'using System;'
        'using System.Collections.Generic;'
        'using System.Runtime.InteropServices;'
        'public static class PcMetrics {'
        '    [StructLayout(LayoutKind.Sequential)] private struct FILETIME { public uint Low; public uint High; }'
        '    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetSystemTimes(out FILETIME idle, out FILETIME kernel, out FILETIME user);'
        '    [StructLayout(LayoutKind.Sequential)] public struct MEMORYSTATUSEX {'
        '        public uint dwLength; public uint dwMemoryLoad; public ulong ullTotalPhys; public ulong ullAvailPhys;'
        '        public ulong ullTotalPageFile; public ulong ullAvailPageFile; public ulong ullTotalVirtual;'
        '        public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual; }'
        '    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);'
        '    [DllImport("powrprof.dll")] private static extern uint CallNtPowerInformation(int level, IntPtr inBuf, uint inSize, IntPtr outBuf, uint outSize);'
        '    [StructLayout(LayoutKind.Explicit)] private struct PdhVal { [FieldOffset(0)] public uint status; [FieldOffset(8)] public double dbl; }'
        '    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] private static extern uint PdhOpenQueryW(string src, IntPtr user, out IntPtr q);'
        '    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] private static extern uint PdhAddEnglishCounterW(IntPtr q, string path, IntPtr user, out IntPtr c);'
        '    [DllImport("pdh.dll")] private static extern uint PdhCollectQueryData(IntPtr q);'
        '    [DllImport("pdh.dll")] private static extern uint PdhGetFormattedCounterValue(IntPtr c, uint fmt, out uint t, out PdhVal v);'
        '    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] private static extern uint PdhEnumObjectItemsW(string src, string machine, string obj, IntPtr counters, ref uint csz, IntPtr instances, ref uint isz, uint detail, uint flags);'
        '    private static List<IntPtr> pdhCoreCounters = new List<IntPtr>();'
        '    private static IntPtr pdhQuery = IntPtr.Zero, pdhPerf = IntPtr.Zero, pdhFreq = IntPtr.Zero;'
        '    private static bool pdhOk;'
        '    private static int pdhLastTick;'
        '    private static ulong lastIdle, lastKernel, lastUser;'
        '    private static bool hasLast;'
        '    private static ulong U64(FILETIME t) { return ((ulong)t.High << 32) | t.Low; }'
        '    public static double CpuPercent() {'
        '        FILETIME i, k, u;'
        '        if (!GetSystemTimes(out i, out k, out u)) return -1;'
        '        ulong idle = U64(i), kernel = U64(k), user = U64(u);'
        '        if (!hasLast) { lastIdle = idle; lastKernel = kernel; lastUser = user; hasLast = true; return -1; }'
        '        ulong dIdle = idle - lastIdle, dKernel = kernel - lastKernel, dUser = user - lastUser;'
        '        lastIdle = idle; lastKernel = kernel; lastUser = user;'
        '        ulong total = dKernel + dUser;'
        '        if (total == 0) return -1;'
        '        double busy = (double)(total - dIdle) / (double)total * 100.0;'
        '        if (busy < 0) busy = 0; if (busy > 100) busy = 100;'
        '        return busy;'
        '    }'
        '    public static double[] MemMb() {'
        '        MEMORYSTATUSEX m = new MEMORYSTATUSEX();'
        '        m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));'
        '        if (!GlobalMemoryStatusEx(ref m)) return new double[] { -1, -1 };'
        '        return new double[] { Math.Round((m.ullTotalPhys - m.ullAvailPhys) / 1048576.0), Math.Round(m.ullTotalPhys / 1048576.0) };'
        '    }'
        '    public static bool PdhInit() {'
        '        if (pdhOk) return true;'
        '        IntPtr q;'
        '        if (PdhOpenQueryW(null, IntPtr.Zero, out q) != 0) return false;'
        '        IntPtr cp, cf;'
        '        if (PdhAddEnglishCounterW(q, "\\Processor Information(_Total)\\% Processor Performance", IntPtr.Zero, out cp) != 0) return false;'
        '        if (PdhAddEnglishCounterW(q, "\\Processor Information(_Total)\\Processor Frequency", IntPtr.Zero, out cf) != 0) return false;'
        '        uint csz = 0, isz = 0;'
        '        PdhEnumObjectItemsW(null, null, "Processor Information", IntPtr.Zero, ref csz, IntPtr.Zero, ref isz, 0, 0);'
        '        if (isz > 0 || csz > 0) {'
        '            IntPtr iBuf = Marshal.AllocHGlobal((int)Math.Max(2, isz) * 2);   // 长度单位是 WCHAR，按字节要 ×2'
        '            IntPtr cBuf = Marshal.AllocHGlobal((int)Math.Max(2, csz) * 2);'
        '            try {'
        '                if (PdhEnumObjectItemsW(null, null, "Processor Information", cBuf, ref csz, iBuf, ref isz, 0, 0) == 0) {'
        '                    long p = iBuf.ToInt64();'
        '                    while (true) {'
        '                        string s = Marshal.PtrToStringUni(new IntPtr(p));'
        '                        if (string.IsNullOrEmpty(s)) break;'
        '                        p += (s.Length + 1) * 2;'
        '                        if (s == "_Total") continue;'
        '                        IntPtr cc;'
        '                        if (PdhAddEnglishCounterW(q, "\\Processor Information(" + s + ")\\% Processor Performance", IntPtr.Zero, out cc) == 0) { pdhCoreCounters.Add(cc); }'
        '                    }'
        '                }'
        '            } finally { Marshal.FreeHGlobal(iBuf); Marshal.FreeHGlobal(cBuf); }'
        '        }'
        '        pdhQuery = q; pdhPerf = cp; pdhFreq = cf; pdhOk = true;'
        '        PdhCollectQueryData(pdhQuery);'
        '        pdhLastTick = Environment.TickCount;'
        '        return true;'
        '    }'
        '    public static string PdhSample() {'
        '        if (!pdhOk && !PdhInit()) return "";'
        '        PdhCollectQueryData(pdhQuery);'
        '        int nowTick = Environment.TickCount;'
        '        if (pdhLastTick != 0 && nowTick - pdhLastTick < 400) return "";'
        '        pdhLastTick = nowTick;'
        '        uint t; PdhVal freq, avg;'
        '        if (PdhGetFormattedCounterValue(pdhFreq, 0x200, out t, out freq) != 0 || freq.status != 0 || freq.dbl <= 0) return "";'
        '        string avgs = "";'
        '        if (PdhGetFormattedCounterValue(pdhPerf, 0x200, out t, out avg) == 0 && avg.status == 0) avgs = Math.Round(freq.dbl * avg.dbl / 100.0).ToString();'
        '        double mx = 0;'
        '        for (int i = 0; i < pdhCoreCounters.Count; i++) {'
        '            PdhVal v;'
        '            if (PdhGetFormattedCounterValue(pdhCoreCounters[i], 0x200, out t, out v) == 0 && v.status == 0 && v.dbl > mx) mx = v.dbl;'
        '        }'
        '        string maxs = mx > 0 ? Math.Round(freq.dbl * mx / 100.0).ToString() : "";'
        '        return avgs + "|" + maxs;'
        '    }'
        '}'
    ) -join "`n"
    try { Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop } catch { }
}

# ---- GPU：一次 nvidia-smi 查询取多字段 ----
if ($SmiPath -and (Test-Path -LiteralPath $SmiPath)) {
    try {
        $line = (& $SmiPath --query-gpu=utilization.gpu,clocks.current.graphics,clocks.current.memory,temperature.gpu,power.draw,fan.speed,memory.used,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
        if ($line) {
            $parts = @(([string]$line) -split ',' | ForEach-Object { $_.Trim() })
            if ($parts.Count -ge 8) {
                $out.gpu = ToNum $parts[0]
                $out.gpuClock = ToNum $parts[1]
                $out.gpuMemClock = ToNum $parts[2]
                $out.gpuTemp = ToNum $parts[3]
                $out.gpuPower = ToNum $parts[4]
                $out.gpuFan = ToNum $parts[5]
                $out.vramUsed = ToNum $parts[6]
                $out.vramTotal = ToNum $parts[7]
            }
        }
    } catch { }
}

# ---- CPU 使用率：主路径 GetSystemTimes（<1 ms），失败再退回 CIM ----
if ('PcMetrics' -as [type]) {
    try { $v = [PcMetrics]::CpuPercent(); if ($v -ge 0) { $out.cpu = [math]::Round($v, 0) } } catch { }
}
if ($null -eq $out.cpu -and -not ('PcMetrics' -as [type])) {
    try {
        $p = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
        $out.cpu = ToNum $p.PercentProcessorTime
    } catch { }
}

# ---- CPU 有效频率：PDH 计数器（ProcessorFrequency × %ProcessorPerformance）----
# 说明：CallNtPowerInformation 的 CurrentMhz 在本机只给 2007/2501 两档粗值，
# 明显低于任务管理器/厂商工具看到的 ~3.5 GHz，所以改用计数器口径（同 Task Manager）。
if ('PcMetrics' -as [type]) {
    try {
        $ps1 = [PcMetrics]::PdhSample()
        if ($ps1) {
            $parts = $ps1 -split '\|'
            $a = 0.0; $b = 0.0
            if ($parts.Count -ge 1 -and [double]::TryParse($parts[0], [ref]$a) -and $a -gt 0) { $out.cpuMhz = [math]::Round($a, 0) }
            if ($parts.Count -ge 2 -and [double]::TryParse($parts[1], [ref]$b) -and $b -gt 0) { $out.cpuMhzMax = [math]::Round($b, 0) }
        }
    } catch { }
}
if ($null -eq $out.cpuMhz -and -not ('PcMetrics' -as [type])) {
    try {
        $pi = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
        $perf = ToNum $pi.PercentProcessorPerformance
        $freq = ToNum $pi.ProcessorFrequency
        if ($null -ne $perf -and $null -ne $freq) { $out.cpuMhz = [math]::Round($freq * $perf / 100.0, 0) }
    } catch { }
}

# ---- 内存（MB）：主路径 GlobalMemoryStatusEx，失败再退回 CIM ----
if ('PcMetrics' -as [type]) {
    try {
        $m = [PcMetrics]::MemMb()
        if ($m[0] -ge 0 -and $m[1] -gt 0) { $out.ramUsed = $m[0]; $out.ramTotal = $m[1] }
    } catch { }
}
if ($null -eq $out.ramTotal -and -not ('PcMetrics' -as [type])) {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $totKb = ToNum $os.TotalVisibleMemorySize
        $freeKb = ToNum $os.FreePhysicalMemory
        if ($null -ne $totKb -and $null -ne $freeKb) {
            $out.ramTotal = [math]::Round($totKb / 1024, 0)
            $out.ramUsed = [math]::Round(($totKb - $freeKb) / 1024, 0)
        }
    } catch { }
}

$Queue.Enqueue([pscustomobject]$out)
    Start-Sleep -Milliseconds $IntervalMs
}
'@

# ---------- 能力探测 ----------
function Get-MetricsCapabilities {
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    $script:MetricsSmiPath = if (Test-Path -LiteralPath $smi) { $smi } else { '' }
    $base = 0
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cpu -and $cpu.MaxClockSpeed) { $base = [int]$cpu.MaxClockSpeed }
    } catch { }
    $script:MetricsCpuBaseMhz = $base

    $script:MetricsCaps = @{
        # true=可用，false=不可用，$null=未探测
        gpu = [bool]$script:MetricsSmiPath
        gpuClock = $null
        gpuMemClock = $null
        gpuTemp = $null
        gpuPower = $null
        gpuFan = $null
        vram = $null
        cpu = $null
        cpuMhz = $null
        cpuMhzMax = $null
        ram = $null
        # 本轮不做，占位：将来由「可选传感器组件」置 true
        cpuTemp = $false
        cpuFan = $false
        diskTemp = $false
        sensorPack = $false
        # 元信息
        intervalMs = $script:MetricsIntervalMs
        ringSize = $script:MetricsRingSize
        cpuBaseMhz = $base
        cpuBarMax = [int]([math]::Round($base * 1.5))
        gpuName = ''
    }
    if ($script:MetricsSmiPath) {
        try {
            $n = (& $script:MetricsSmiPath --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1)
            if ($n) { $script:MetricsCaps.gpuName = ([string]$n).Trim() }
        } catch { }
    }
    return $script:MetricsCaps
}

# 用真实样本校正能力表：字段为 null 说明这台机器拿不到该传感器
function Update-MetricsCapsFromSample($s) {
    if (-not $script:MetricsCaps -or -not $s) { return }
    $c = $script:MetricsCaps
    $c.gpu = ($null -ne $s.gpu)
    $c.gpuClock = ($null -ne $s.gpuClock)
    $c.gpuMemClock = ($null -ne $s.gpuMemClock)
    $c.gpuTemp = ($null -ne $s.gpuTemp)
    $c.gpuPower = ($null -ne $s.gpuPower)
    $c.gpuFan = ($null -ne $s.gpuFan)
    $c.vram = ($null -ne $s.vramTotal)
    $c.cpu = ($null -ne $s.cpu)
    $c.cpuMhz = ($null -ne $s.cpuMhz)
    $c.cpuMhzMax = ($null -ne $s.cpuMhzMax)
    $c.ram = ($null -ne $s.ramTotal)
}

# ---------- 采样调度 ----------
# 采样线程只创建一次：C# 里编译的原生类型与 PDH 查询都是**进程级静态状态**，
# 每轮重建 runspace 会重新编译类型（静态状态归零、PDH 查询泄漏），
# 表现为「首轮永远没有频率、退出时访问冲突 0xC0000005」。
# 所以：常驻 runspace 循环采样 → ConcurrentQueue 回传 → 宿主计时器取走。
function Start-MetricsWorker {
    if ($script:MetricsWorker) { return }
    try {
        if (-not $script:MetricsQueue) {
            $script:MetricsQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        }
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($script:MetricsSampleScript)
        [void]$ps.AddParameter('SmiPath', $script:MetricsSmiPath)
        [void]$ps.AddParameter('Queue', $script:MetricsQueue)
        [void]$ps.AddParameter('IntervalMs', $script:MetricsIntervalMs)
        if (-not $script:MetricsCtl) { $script:MetricsCtl = @{ stop = $false } }
        $script:MetricsCtl.stop = $false
        [void]$ps.AddParameter('Ctl', $script:MetricsCtl)
        $handle = $ps.BeginInvoke()
        $script:MetricsWorker = @{ PS = $ps; Handle = $handle; Started = (Get-Date) }
        Write-AppLog '监控采样线程已启动（常驻 runspace）'
    } catch {
        Write-AppLog ('启动监控采样失败: ' + $_.Exception.Message) 'WARN'
        $script:MetricsWorker = $null
    }
}

function Stop-MetricsWorker {
    if (-not $script:MetricsWorker) { return }
    $w = $script:MetricsWorker
    # 先让采样循环自己退出（协作式），避免在原生调用里被硬中断
    if ($script:MetricsCtl) { $script:MetricsCtl.stop = $true }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $w.Handle.IsCompleted -and $sw.ElapsedMilliseconds -lt 2500) { Start-Sleep -Milliseconds 50 }
    if (-not $w.Handle.IsCompleted) { try { $w.PS.Stop() } catch { } }
    try { [void]$w.PS.EndInvoke($w.Handle) } catch { }
    try { $w.PS.Dispose() } catch { }
    $script:MetricsWorker = $null
    if ($script:MetricsQueue) {
        $tmp = $null
        while ($script:MetricsQueue.TryDequeue([ref]$tmp)) { }
    }
}

function Invoke-MetricsTick {
    if (-not $script:MetricsRunning) { return }
    # 采样线程死了就报一次，别静默
    if ($script:MetricsWorker -and $script:MetricsWorker.Handle.IsCompleted) {
        $err = $null
        try { $err = $script:MetricsWorker.Handle.AsyncState } catch { }
        Write-AppLog '监控采样线程已退出（可能是原生调用异常），本次会话停止采样' 'WARN'
        Stop-MetricsWorker
        $script:MetricsRunning = $false
        Stop-MetricsTimer
        Send-ToUi @{ type = 'metricsCaps'; caps = $script:MetricsCaps; running = $false; error = 'worker-stopped' }
        return
    }
    if (-not $script:MetricsQueue) { return }
    $sample = $null
    while ($script:MetricsQueue.TryDequeue([ref]$sample)) {
        if (-not $sample) { continue }
        [void]$script:MetricsSamples.Add($sample)
        while ($script:MetricsSamples.Count -gt $script:MetricsRingSize) { $script:MetricsSamples.RemoveAt(0) }
        Update-MetricsCapsFromSample $sample
        Send-ToUi @{ type = 'metricSample'; sample = $sample; caps = $script:MetricsCaps }
    }
}

function Send-MetricsCaps {
    if (-not $script:MetricsCaps) { return }
    Send-ToUi @{ type = 'metricsCaps'; caps = $script:MetricsCaps; running = $script:MetricsRunning }
}

function Stop-MetricsTimer {
    if ($script:MetricsTimer) {
        try { $script:MetricsTimer.Stop(); $script:MetricsTimer.Dispose() } catch { }
        $script:MetricsTimer = $null
    }
}

function Set-MetricsConsumer {
    param([string]$Name, [bool]$On)
    if (-not $script:MetricsConsumers) { $script:MetricsConsumers = @{} }
    if ($On) { $script:MetricsConsumers[$Name] = $true } else { $script:MetricsConsumers.Remove($Name) }
    if ($script:MetricsConsumers.Count -gt 0) { Start-MetricsSampler } else { Stop-MetricsSampler }
}

function Start-MetricsSampler {
    if ($script:MetricsRunning) { return }
    Get-MetricsCapabilities | Out-Null
    $script:MetricsRunning = $true
    $script:MetricsSamples.Clear()
    Start-MetricsWorker
    Send-MetricsCaps
    Write-AppLog (("实时监控开始：间隔 {0} ms，环形缓冲 {1} 点，GPU 源 {2}" -f $script:MetricsIntervalMs, $script:MetricsRingSize, $(if ($script:MetricsSmiPath) { 'nvidia-smi' } else { '无' })))

    Stop-MetricsTimer
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.add_Tick({
        try { Invoke-MetricsTick } catch { Write-AppLog ('监控计时器异常: ' + $_.Exception.Message) 'WARN'; Stop-MetricsTimer }
    })
    $timer.Start()
    $script:MetricsTimer = $timer
}

function Stop-MetricsSampler {
    if (-not $script:MetricsRunning -and -not $script:MetricsTimer) { return }
    $script:MetricsRunning = $false
    Stop-MetricsTimer
    Stop-MetricsWorker
    Send-ToUi @{ type = 'metricsCaps'; caps = $script:MetricsCaps; running = $false }
    Write-AppLog '实时监控已停止'
}

# 供桥接调用：start/stop 都幂等
function Invoke-MetricsCommand {
    param($Msg)
    switch ($Msg.cmd) {
        'metricsStart' { Set-MetricsConsumer -Name 'page' -On $true }
        'metricsStop' { Set-MetricsConsumer -Name 'page' -On $false }
    }
}
