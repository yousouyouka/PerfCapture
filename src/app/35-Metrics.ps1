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
# 实时 FPS（批次 C）：独立 PresentMon 增量 tail，目标进程取「采集页上次选中的进程」
$script:MetricsPmPath = ''
$script:MetricsFpsPid = 0
$script:MetricsFpsName = ''
$script:MetricsFpsCsv = ''

# ---------- 一轮采样（runspace 里执行；单引号 here-string，禁止变量展开） ----------
$script:MetricsSampleScript = @'
param($SmiPath, $Queue, $IntervalMs, $Ctl, $PmExe, $FpsCsv, $FpsPid)

# ---- 实时 FPS：PresentMon 增量 tail ----
# 目标进程 = 当前前台窗口的进程（排除本程序自己），退回「采集页上次选中的进程」$FpsPid。
# 前台切换时重建 tail；PresentMon 被杀不会自动移除 ETW 会话，所以每次启动都带
# --session_name 固定名 + --stop_existing_session，避免「trace session already running」静默失败。
if (-not ('PerfFg' -as [type])) {
    Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class PerfFg{[DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();[DllImport("user32.dll")]public static extern int GetWindowThreadProcessId(IntPtr h,out int pid);public static int Pid(){int p=0;GetWindowThreadProcessId(GetForegroundWindow(),out p);return p;}}' -ErrorAction SilentlyContinue
}
$hostPid = $PID
$fps = @{ proc = $null; offset = 0; sw = $null; leftover = ''; header = $false; framesSeen = 0; ok = $false;
          pid = 0; target = ''; err = ''; errFile = ''; cand = -1; hits = 0; win = @(); starve = 0; session = '' }

function Resolve-FpsTarget {
    param([int]$Fallback)
    $fg = 0
    try { if ('PerfFg' -as [type]) { $fg = [PerfFg]::Pid() } } catch { $fg = 0 }
    if ($fg -gt 0 -and $fg -ne $hostPid) { return $fg }
    if ($Fallback -gt 0) {
        try { [void](Get-Process -Id $Fallback -ErrorAction Stop); return $Fallback } catch { }
    }
    return 0
}

function Stop-FpsTail {
    if ($fps.proc) { try { if (-not $fps.proc.HasExited) { Stop-Process -Id $fps.proc.Id -Force } } catch { } }
    # 杀掉 PresentMon 不会自动移除它的 ETW 会话，顺手 stop 掉自己那一个（唯一名，不会误伤别人）
    if ($fps.session) {
        try { & (Join-Path $env:SystemRoot 'System32\logman.exe') stop $fps.session -ets 2>&1 | Out-Null } catch { }
        $fps.session = ''
    }
    $fps.proc = $null
    $fps.ok = $false
    $fps.pid = 0
    $fps.target = ''
}

# 开采集前清场：上一轮 PresentMon 被强杀会留下**卡死的 ETW 会话**，它占着 DxgKrnl 之后
# 新会话一帧也收不到（实测：清掉 PerfCaptureLive_*/PresentMon 后，同一目标 8 秒立刻出 1661 帧）。
function Clear-FpsSessions {
    # 先杀掉上次没被收掉的 presentmon：它们还占着同一个 CSV 与 ETW 会话，
    # 新实例会因为会话/文件抢占拿不到数据（实测 csv 一直在长但行数计 0）
    try { Get-Process -Name presentmon -ErrorAction SilentlyContinue | ForEach-Object { try { Stop-Process -Id $_.Id -Force } catch { } } } catch { }
    try {
        $logman = Join-Path $env:SystemRoot 'System32\logman.exe'
        $q = (& $logman query -ets 2>&1 | Out-String)
        foreach ($m in [regex]::Matches($q, '(?m)^(PerfCaptureLive\S*|PresentMon\S*)\s+')) {
            $n = $m.Groups[1].Value
            if ($n) { & $logman stop $n -ets 2>&1 | Out-Null }
        }
    } catch { }
}

function Start-FpsTail {
    param([int]$TargetPid)
    Stop-FpsTail
    $fps.offset = 0; $fps.leftover = ''; $fps.header = $false; $fps.framesSeen = 0; $fps.err = ''; $fps.win = @(); $fps.starve = 0
    if (-not $PmExe -or -not $FpsCsv -or $TargetPid -le 0) { return }
    if (-not (Test-Path -LiteralPath $PmExe)) { return }
    try {
        if (Test-Path -LiteralPath $FpsCsv) { Remove-Item -LiteralPath $FpsCsv -Force -ErrorAction SilentlyContinue }
        # 实测结论：PresentMon 对 --output_file 是独占打开（FileShare.None），采样器跨进程读不到，
        # 行数永远 0 —— 这是实时 FPS 一直不显示的**直接原因**；而 --output_stdout 走管道是块缓冲
        # （重定向后 8 秒只有 2 字节），同样拿不到。所以「边采边读」这条路在当前版本上不成立，
        # 需改成「短窗口采集 + 退出后解析」（burst 模式），见 CHANGELOG 1.5.7 的说明。
        $fps.session = 'PerfCaptureLive_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $pmArgs = @('--process_id', "$TargetPid", '--output_file', $FpsCsv, '--v2_metrics', '--no_console_stats',
                    '--session_name', $fps.session)
        $fps.proc = Start-Process -FilePath $PmExe -ArgumentList $pmArgs -PassThru -WindowStyle Hidden
        $fps.sw = [Diagnostics.Stopwatch]::StartNew()
        $fps.ok = $true
        $fps.pid = $TargetPid
        try { $fps.target = (Get-Process -Id $TargetPid -ErrorAction Stop).ProcessName } catch { $fps.target = '' }
    } catch {
        $fps.ok = $false
        $fps.err = 'start: ' + $_.Exception.Message
        $fps.pid = 0
    }
}

# PresentMon 起来就退出（未提权 / 会话冲突 / 参数错）时，把原因交给宿主记日志。
# 不读 stderr（runspace 里带重定向会卡），改用退出码 + 一句可读解释。
function Test-FpsTailDead {
    if (-not $fps.proc) { return }
    $exited = $false
    try { $fps.proc.Refresh(); $exited = $fps.proc.HasExited } catch { $exited = $false }
    if (-not $exited) { return }
    $code = $null
    try { $code = $fps.proc.ExitCode } catch { }
    # 退出码 6 = PresentMon 建不了 ETW 会话（最常见就是没提权）；4201 那条已经用唯一会话名规避
    if ($code -eq 6) {
        $fps.err = 'PresentMon 无法创建 ETW 会话（退出码 6）：需要以管理员身份运行 PerfCapture'
    } else {
        $fps.err = 'presentmon exited early (exit code ' + $code + '); 常见原因：未提权或 ETW 会话被占用'
    }
    $fps.ok = $false
    $fps.proc = $null
    $fps.pid = 0
    $fps.target = ''
}
function Read-NewFrames {
    if (-not $fps.ok) { return 0 }
    if (-not (Test-Path -LiteralPath $FpsCsv)) { return 0 }
    # PresentMon 用独占方式持有输出文件，若这里抛「文件正由另一进程使用」，说明读取方拿不到数据 ——
    # 把异常原文留在 $fps.err 里（宿主会写进日志），不要再静默成 0。
    $fs = $null
    foreach ($sh in @([IO.FileShare]::ReadWrite, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete), [IO.FileShare]::Read)) {
        try { $fs = [IO.File]::Open($FpsCsv, [IO.FileMode]::Open, [IO.FileAccess]::Read, $sh); break }
        catch { $fps.err = 'read: ' + $_.Exception.Message; $fs = $null }
    }
    if (-not $fs) { return 0 }
    $txt = ''
    try {
        $fps.err = ''
        if ($fs.Length -le $fps.offset) { return 0 }
        [void]$fs.Seek($fps.offset, [IO.SeekOrigin]::Begin)
        $sr = New-Object IO.StreamReader($fs)
        $txt = $sr.ReadToEnd()
        $fps.offset = $fs.Position
        $sr.Dispose()
    } catch {
        $fps.err = 'read: ' + $_.Exception.Message
        return 0
    } finally { $fs.Dispose() }
    if (-not $txt) { return 0 }
    $all = [string]$fps.leftover + $txt
    $nl = $all.LastIndexOf("`n")
    if ($nl -lt 0) { $fps.leftover = $all; return 0 }
    $complete = $all.Substring(0, $nl)
    $fps.leftover = $all.Substring($nl + 1)
    $n = 0
    foreach ($line in ($complete -split "`r?`n")) {
        if (-not $line) { continue }
        if (-not $fps.header) { $fps.header = $true; continue }   # 第一行是表头
        $n++
    }
    $fps.framesSeen += $n
    return $n
}

# 采样循环启动前先清一次残留 ETW 会话（卡死的会话会让后面所有 tail 收不到帧）
Clear-FpsSessions
while ($true) {
    if ($Ctl -and $Ctl.stop) { break }
# 目标选择：优先跟随前台，但**只在当前目标没在出帧时才换** ——
# 1.5.4 实测：alt-tab 到浏览器/任务管理器就重开 tail，帧数永远攒不起来，FPS 一直空。
$cand = Resolve-FpsTarget -Fallback $FpsPid
if ($cand -ne $fps.cand) { $fps.cand = $cand; $fps.hits = 0 } else { $fps.hits++ }
if ($cand -gt 0 -and $cand -ne $fps.pid) {
    if (-not $fps.proc) { Start-FpsTail -TargetPid $cand }
    elseif ($fps.hits -ge 3 -and $fps.starve -ge 6) { Start-FpsTail -TargetPid $cand }   # 当前 6 秒无帧 + 新目标稳定 3 秒
}
Test-FpsTailDead
if ($fps.pid -gt 0) {
    $alive = $true
    try { [void](Get-Process -Id $fps.pid -ErrorAction Stop) } catch { $alive = $false }
    if (-not $alive) { Stop-FpsTail }
}
$out = [ordered]@{
    at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    cpu = $null; cpuMhz = $null; cpuMhzMax = $null
    gpu = $null; gpuClock = $null; gpuMemClock = $null; gpuTemp = $null; gpuPower = $null; gpuFan = $null
    vramUsed = $null; vramTotal = $null
    ramUsed = $null; ramTotal = $null
    fps = $null
    fpsTarget = $fps.target
    fpsErr = $fps.err
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

# ---- 实时 FPS（PresentMon 增量）----
# 只有这一轮真的解析出帧才「结账并重置窗口」：否则生产者一次写一批会让读数在 0 与真值之间抖动。
# 连续 2 秒以上没有新帧，才判定为「游戏不出了」，如实报 0（而不是一直显示上一次的旧值）。
if ($fps.ok) {
    $n = Read-NewFrames
    if ($n -le 0) { $fps.starve++ }
    if ($fps.sw) {
        $elapsed = $fps.sw.Elapsed.TotalSeconds
        if ($n -gt 0 -and $fps.framesSeen -gt 0 -and $elapsed -gt 0.2) {
            $fps.starve = 0
            # 3 窗口滑动平均：PresentMon 是一次批写、采样又是一秒一读，直接 n/elapsed 会周期性冒出
            # 双倍和半量的尖峰（实测 54 / 7.3 交替）。用最近 3 个窗口合计后相除，读数才稳。
            $fps.win += (, @([double]$n, [double]$elapsed))
            while ($fps.win.Count -gt 3) { $fps.win.RemoveAt(0) }
            $fn = 0.0; $ft = 0.0
            foreach ($w in $fps.win) { $fn += $w[0]; $ft += $w[1] }
            if ($ft -gt 0) { $out.fps = [math]::Round($fn / $ft, 1) }
            $fps.sw.Restart()
        } elseif ($elapsed -gt 2.0) {
            if ($fps.framesSeen -gt 0) { $out.fps = 0.0 }
            $fps.win = @()
            $fps.sw.Restart()
        }
    }
    # 6 秒一帧都没有：把原因交回宿主记一次日志，别让界面永远只显示「—」
    if ($fps.starve -eq 6 -and $fps.framesSeen -eq 0) {
        # 把现场信息一起写进日志：下次出问题时不用猜是「没起」「起错参数」还是「起了但没数据」
        $csvInfo = if (Test-Path -LiteralPath $FpsCsv) { (Get-Item -LiteralPath $FpsCsv).Length } else { 'no-file' }
        $isAdm = $false
        try { $isAdm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
        $out.fpsErr = ('目标 {0}(pid {1}) 连续 6 秒无帧（csv={2}，提权={3}，ok={4}，framesSeen={5}，读错={6}）。' -f
                       $fps.target, $fps.pid, $csvInfo, $isAdm, $fps.ok, $fps.framesSeen, $(if ($fps.err) { $fps.err } else { '无' }))
    }
}

if ($fps.err) { $fps.err = '' }
$Queue.Enqueue([pscustomobject]$out)
    Start-Sleep -Milliseconds $IntervalMs
}

# 采样循环退出：收掉自己起的 PresentMon 与临时 CSV，绝不留给下一次会话
if ($fps.proc) {
    try { if (-not $fps.proc.HasExited) { Stop-Process -Id $fps.proc.Id -Force } } catch { }
}
if ($FpsCsv -and (Test-Path -LiteralPath $FpsCsv)) {
    Remove-Item -LiteralPath $FpsCsv -Force -ErrorAction SilentlyContinue
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

    # 实时 FPS：找 PresentMon（优先随包 tools\，退回 PATH），临时 CSV 放 %TEMP%\PerfCapture
    $script:MetricsPmPath = ''
    try {
        $cand = Join-Path $script:ToolsDir 'presentmon.exe'
        if (Test-Path -LiteralPath $cand) { $script:MetricsPmPath = $cand }
        else {
            $g = Get-Command presentmon -ErrorAction SilentlyContinue
            if ($g) { $script:MetricsPmPath = $g.Source }
        }
    } catch { }
    try {
        if (-not (Test-Path -LiteralPath $script:TempDir)) { New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null }
        $script:MetricsFpsCsv = Join-Path $script:TempDir 'live.presentmon.csv'
    } catch { $script:MetricsFpsCsv = '' }

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
        # 实时 FPS：样本里 fps 非空才算可用；fpsTarget 是当前盯着的进程名
        fps = $false
        fpsTarget = ''
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
        [void]$ps.AddParameter('PmExe', $script:MetricsPmPath)
        [void]$ps.AddParameter('FpsCsv', $script:MetricsFpsCsv)
        [void]$ps.AddParameter('FpsPid', $script:MetricsFpsPid)
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
        if ($sample.fpsErr) { Write-AppLog ('实时 FPS 不可用：' + $sample.fpsErr) 'WARN' }
        if ($sample.fpsTarget -and $sample.fpsTarget -ne $script:MetricsFpsName) {
            $script:MetricsFpsName = $sample.fpsTarget
            $script:MetricsCaps.fpsTarget = $sample.fpsTarget
            Write-AppLog ('实时 FPS 目标切换：' + $sample.fpsTarget)
        }
        if (-not $script:MetricsFirstLogged -and ($null -ne $sample.cpu -or $null -ne $sample.cpuMhz)) {
            $script:MetricsFirstLogged = $true
            Write-AppLog (('实时监控已出数据：cpu={0}% 平均={1}MHz 最高={2}MHz gpu={3}%' -f $sample.cpu, $sample.cpuMhz, $sample.cpuMhzMax, $sample.gpu))
        }
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
    # 实时 FPS 的「备选目标」：采集页上次选中的进程（还活着才用）。主目标是当前前台应用，见采样脚本。
    $script:MetricsFpsPid = 0
    $script:MetricsFpsName = ''
    try {
        $lp = [int]$script:Cfg.lastPid
        if ($lp -gt 0) {
            $p = Get-Process -Id $lp -ErrorAction Stop
            $script:MetricsFpsPid = $p.Id
            $script:MetricsFpsName = $p.ProcessName
        }
    } catch { }
    $script:MetricsRunning = $true
    $script:MetricsSamples.Clear()
    $script:MetricsFirstLogged = $false
    # 能力表：只要 PresentMon 与输出路径就绪就算可用；目标进程改成每轮跟随前台，
    # 不再依赖「上次采集过的进程」——那个 pid 常常早就退出了（FPS 一直不出值的根因之一）。
    if ($script:MetricsCaps) {
        $script:MetricsCaps.fps = ([bool]$script:MetricsPmPath -and [bool]$script:MetricsFpsCsv)
        $adm = $false
        try { $adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
        $script:MetricsCaps.fpsAdmin = $adm
        if (-not $adm) { Write-AppLog '实时 FPS 需要管理员权限：当前进程未提权，PresentMon 无法建立 ETW 会话（FPS 只会显示「—」）' 'WARN' }
        $script:MetricsCaps.fpsTarget = $script:MetricsFpsName
    }
    Start-MetricsWorker
    Send-MetricsCaps
    $fpsNote = if ($script:MetricsPmPath -and $script:MetricsFpsCsv) {
        $fb = if ($script:MetricsFpsPid -gt 0) { ('；无前台时退回 ' + $script:MetricsFpsName + '(' + $script:MetricsFpsPid + ')') } else { '' }
        'FPS 跟随前台应用' + $fb
    } else { 'FPS 未启用（缺少 PresentMon）' }
    Write-AppLog (("实时监控开始：间隔 {0} ms，环形缓冲 {1} 点，GPU 源 {2}，{3}" -f $script:MetricsIntervalMs, $script:MetricsRingSize, $(if ($script:MetricsSmiPath) { 'nvidia-smi' } else { '无' }), $fpsNote))

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
