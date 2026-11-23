<#
  Game performance capture + report (generic, any game)
  - Capture backend : Intel PresentMon 2.6 (ETW, NO code injection -> DLSS stays intact)
  - Sensors         : nvidia-smi (GPU temp / GPU util) + GPU Process Memory counter (per-app VRAM)
                      + Get-Process (per-app RAM)
  Report metrics    : avg FPS, 1% low FPS, display latency, GPU usage, GPU temp, VRAM(this app), RAM(this app)
#>
param(
    [int]$Seconds = 120,
    [int]$Countdown = 0,
    [int]$ProcessId = 0,
    [string]$Label = 'run',
    [string]$ProcessName = 'Endfield.exe',
    [string]$OutDir = (Join-Path $PSScriptRoot 'reports'),
    [switch]$NoPause,
    [string]$Skip = '',
    [string]$Theme = 'dark',
    [string]$HtmlPath = '',
    [int]$WarmupSec = 0,          # 预热丢弃：丢掉开头这么多秒的帧（管线/编译着色器造成的假卡顿）
    [switch]$NoElevate,           # 仅供自动化测试：跳过自我提权（正常使用不要加）
    [int]$StutterMs = 50,         # 卡顿阈值：单帧超过这个毫秒数记一次卡顿
    [string]$FpsSource = 'presentmon'  # 帧数据源：presentmon 或扩展 id（单一来源，写入报告元数据）
)

# ---------------------------------------------------------------- collection switches
# -Skip latency,gputemp,gpuusage,vram,ram,features,res  (empty = collect everything)
# 旧配置兼容：gpu = gputemp + gpuusage；mem = vram + ram（1.2 及更早只有这两个粗开关）
if ($Theme -ne 'light') { $Theme = 'dark' }
$skipList = @()
foreach ($k in ($Skip -split ',')) { $k = $k.Trim().ToLower(); if ($k) { $skipList += $k } }
if ($skipList -contains 'gpu') { $skipList += 'gputemp', 'gpuusage' }
if ($skipList -contains 'mem') { $skipList += 'vram', 'ram' }
# 帧数据源：单一来源口径，值只允许 presentmon 或「字母数字-点-下划线」的扩展 id。
# 不合法就回退基线并标注，不让外部参数把任意字符串写进报告元数据。
if (-not $FpsSource -or $FpsSource -notmatch '^[A-Za-z0-9._-]{1,64}$') { $FpsSource = 'presentmon' }
$collectLatency  = -not ($skipList -contains 'latency')
$collectGpuTemp  = -not ($skipList -contains 'gputemp')
$collectGpuUsage = -not ($skipList -contains 'gpuusage')
$collectVram     = -not ($skipList -contains 'vram')
$collectRam      = -not ($skipList -contains 'ram')
# 2.0.5：把 B1 的三项遥测拆成独立开关（原先都挂在 ram 上，界面上只能整块开关）
$collectProcCpu  = -not ($skipList -contains 'proccpu')
$collectSysMem   = -not ($skipList -contains 'sysmem')
$collectShared   = -not ($skipList -contains 'sharedmem')
$collectCpuPower = -not ($skipList -contains 'cpupower')   # 2.0.17：CPU 封装功耗（PDH Energy Meter）
# 2.1.12：CPU 温度与降频进可选清单。默认开（与 2.1.11 行为一致），关掉可省掉 WMI 与事件日志查询。
$collectCpuTemp  = -not ($skipList -contains 'cputemp')
$collectCpuThrottle = -not ($skipList -contains 'cputhrottle')
$collectFeatures = -not ($skipList -contains 'features')
$collectRes      = -not ($skipList -contains 'res')
$collectChart    = $true      # 图表始终生成：UI 不再提供开关，报告里必定含曲线
$collectGpuSensors = $collectGpuTemp -or $collectGpuUsage   # 两者共用一次 nvidia-smi 查询
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 规则模块
# 采集引擎跑在独立进程里（由 60-Capture.ps1 拉起），宿主加载的函数在这里不存在。
# 平台规则 / 厂商温度 / 降频这三个模块无 UI 依赖，直接点源即可；
# 缺文件时对应能力降级为 N/A，不影响帧采集（见《数据源与平台覆盖规则.md》§5）。
$script:AppModuleDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'app'
foreach ($m in @('platform-rules.ps1', 'vendor-sensor.ps1', 'cpu-throttle.ps1', 'quality-rules.ps1', 'stutter-context.ps1')) {
    $mp = Join-Path $script:AppModuleDir $m
    if (Test-Path -LiteralPath $mp) { . $mp }
}

# ---------------------------------------------------------------- elevation
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $NoElevate) {
    $ps = (Get-Process -Id $PID).Path
    if (-not $ps) { $ps = 'powershell.exe' }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Seconds', $Seconds, '-Countdown', $Countdown, '-ProcessId', $ProcessId, '-ProcessName', ('"' + $ProcessName + '"'), '-Label', ('"' + $Label + '"'), '-OutDir', ('"' + $OutDir + '"'))
    if ($Skip) { $argList += @('-Skip', ('"' + $Skip + '"')) }
    $argList += @('-Theme', $Theme)
    if ($HtmlPath) { $argList += @('-HtmlPath', ('"' + $HtmlPath + '"')) }
    if ($WarmupSec -gt 0) { $argList += @('-WarmupSec', "$WarmupSec") }
    if ($FpsSource) { $argList += @('-FpsSource', ('"' + $FpsSource + '"')) }
    if ($NoPause) { $argList += '-NoPause' }
    Write-Host 'Requesting administrator rights (PresentMon needs an ETW session)...' -ForegroundColor Yellow
    Start-Process $ps -Verb RunAs -ArgumentList ($argList -join ' ') -Wait | Out-Null
    return
}

function Pause-End([string]$msg) { if (-not $NoPause) { Write-Host $msg -ForegroundColor DarkGray; [void](Read-Host) } }

# ---------------------------------------------------------------- locate tools
# prefer the real exe (the WinGet shim is a per-user symlink that misbehaves when elevated)
$pmExe = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter 'presentmon.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
if (-not $pmExe) { $pmExe = (Get-Command presentmon -ErrorAction SilentlyContinue).Source }
if (-not $pmExe) {
    Write-Host 'PresentMon not found. Install it first:  winget install Intel.PresentMon.Console' -ForegroundColor Red
    Pause-End 'Press Enter to exit'; exit 1
}
$smi = 'C:\Windows\System32\nvidia-smi.exe'
if (-not (Test-Path $smi)) { Write-Host 'nvidia-smi not found - GPU temp/usage will be NA.' -ForegroundColor Yellow }

# ---------------------------------------------------------------- find target process
$exeBase = [IO.Path]::GetFileNameWithoutExtension($ProcessName)
$game = $null
if ($ProcessId -gt 0) {
    $game = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $game) {
        Write-Host ("Process with PID " + $ProcessId + " is not running.") -ForegroundColor Red
        Pause-End 'Press Enter to exit'; exit 1
    }
} else {
    $all = @(Get-Process -Name $exeBase -ErrorAction SilentlyContinue)
    if ($all.Count -gt 0) {
        # prefer the instance that owns a visible window: that is the one that presents frames
        $game = $all | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if (-not $game) { $game = $all | Select-Object -First 1 }
    }
}
if (-not $game) {
    Write-Host ("Process not running: " + $ProcessName) -ForegroundColor Red
    Write-Host 'Start the game first, then run this script.' -ForegroundColor Yellow
    Pause-End 'Press Enter to exit'; exit 1
}
$GamePid = $game.Id
if ($game.MainWindowHandle -eq 0) {
    Write-Host 'Warning: this process has no visible window - it may not be rendering.' -ForegroundColor Yellow
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$runName = $stamp + '_' + ($Label -replace '[^\w\-]', '_')
$pmCsv   = Join-Path $OutDir ($runName + '.presentmon.csv')
$sensCsv = Join-Path $OutDir ($runName + '.sensors.csv')
$htmlOut = if ($HtmlPath) { $HtmlPath } else { Join-Path $OutDir ($runName + '.html') }
$htmlDir = Split-Path -Parent $htmlOut
if ($htmlDir -and -not (Test-Path $htmlDir)) { New-Item -ItemType Directory -Path $htmlDir -Force | Out-Null }
$jsonOut = Join-Path $OutDir ($runName + '.json')

Write-Host ''
Write-Host '=== Game performance capture ===' -ForegroundColor Cyan
Write-Host ("  process      : " + $exeBase + " (PID " + $GamePid + ")")
Write-Host ("  duration     : " + $Seconds + " s")
Write-Host ("  session name : EndfieldPerf")
Write-Host '  Note: keep playing normally; the report is printed when the timer ends.' -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------- clear stale ETW session
& logman stop EndfieldPerf -ets  2>$null | Out-Null
& logman stop PresentMon  -ets  2>$null | Out-Null

# ---------------------------------------------------------------- sensor sampler (background job)
# 批次 C：一次 nvidia-smi 取全部 GPU 字段（时钟/功耗/风扇/PCIe/降频原因），
# CPU 每核占用用 CIM 的 formatted data（英文类名，不受系统语言影响）。
# 老驱动/老 nvidia-smi 不认识新字段时整条查询会报错 -> 退回 1.4 的三字段，绝不因此丢数据。
$capStartedAt = Get-Date   # 降频只统计本次采集窗口内的日志事件
$sampler = Start-Job -ArgumentList $GamePid, $sensCsv, ($Seconds + 10), $smi, $collectGpuSensors, $collectVram, $collectRam, $collectProcCpu, $collectSysMem, $collectShared, $collectCpuPower, $script:AppModuleDir -ScriptBlock {
    param($gpid, $csv, $maxSec, $smi, $wantGpu, $wantVram, $wantRam, $wantProcCpu, $wantSysMem, $wantShared, $wantCpuPower, $appDir)
    # 平台规则 + 厂商温度：与宿主同一份源码（避免两套实现算出两种结论）
    foreach ($m in @('platform-rules.ps1', 'vendor-sensor.ps1')) {
        $mp = Join-Path $appDir $m
        if (Test-Path -LiteralPath $mp) { . $mp }
    }
    # 注意：这里不再「所有开关都关就整体 return」——CPU 占用与 CPU 温度是无开关的基础项，
    # 提前返回会让这两项在只关 GPU 采集时凭空消失（历史上就是因此出现过空板块）。

# ---- NvGpu：直调 nvml.dll（<1 ms）替代 nvidia-smi（每次 45–60 ms 进程启动）----
# 任何一项取不到都回退 nvidia-smi，功能不退化。
$gpuUseNvml = $false
if (-not ('NvGpu' -as [type])) {
    $nvcs = @(
        'using System;'
        'using System.Runtime.InteropServices;'
        'public static class NvGpu {'
        '    [DllImport("nvml.dll", EntryPoint = "nvmlInit_v2")] private static extern int Init();'
        '    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetCount_v2")] private static extern int GetCount(out uint n);'
        '    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetHandleByIndex_v2")] private static extern int GetHandle(uint i, out IntPtr h);'
        '    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetUtilizationRates")] private static extern int Util(IntPtr h, out UtilRate r);'
        '    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetTemperature")] private static extern int Temp(IntPtr h, int sensor, out uint t);'
        '    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetPowerUsage")] private static extern int Power(IntPtr h, out uint mw);'
        '    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetClockInfo")] private static extern int Clock(IntPtr h, int type, out uint mhz);'
        '    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetMaxClockInfo")] private static extern int MaxClock(IntPtr h, int type, out uint mhz);'
        '    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetFanSpeed")] private static extern int Fan(IntPtr h, out uint pct);'
        '    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetMemoryInfo")] private static extern int Mem(IntPtr h, out MemInfo m);'
        '    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetCurrPcieLinkGeneration")] private static extern int PcieGen(IntPtr h, out uint g);'
        '    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetCurrPcieLinkWidth")] private static extern int PcieWidth(IntPtr h, out uint w);'
        '    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetCurrentClocksThrottleReasons")] private static extern int Throttle(IntPtr h, out ulong mask);'
        '    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetEnforcedPowerLimit")] private static extern int EnfLimit(IntPtr h, out uint mw);'
        '    [StructLayout(LayoutKind.Sequential)] public struct UtilRate { public uint Gpu; public uint Memory; }'
        '    [StructLayout(LayoutKind.Sequential)] public struct MemInfo { public ulong Total; public ulong Free; public ulong Used; }'
        '    private static IntPtr dev = IntPtr.Zero;'
        '    private static bool tried = false;'
        '    public static bool Start() {'
        '        if (tried) return dev != IntPtr.Zero;'
        '        tried = true;'
        '        try {'
        '            if (Init() != 0) return false;'
        '            uint n; if (GetCount(out n) != 0 || n < 1) return false;'
        '            IntPtr h; if (GetHandle(0, out h) != 0) return false;'
        '            dev = h;'
        '            return true;'
        '        } catch { return false; }'
        '    }'
        '    // gpu%, 图形频率, 显存频率, 温度, 功率W, 风扇%, VRAM已用MB, VRAM总量MB'
        '    public static double[] Sample() {'
        '        if (dev == IntPtr.Zero) return null;'
        '        double gpu = -1, clk = -1, mclk = -1, tmp = -1, pwr = -1, fan = -1, vu = -1, vt = -1;'
        '        try {'
        '            UtilRate u; if (Util(dev, out u) == 0) gpu = u.Gpu;'
        '            uint v;'
        '            if (Clock(dev, 0, out v) == 0) clk = v;'
        '            if (Clock(dev, 2, out v) == 0) mclk = v;'
        '            if (Temp(dev, 0, out v) == 0) tmp = v;'
        '            if (Power(dev, out v) == 0) pwr = v / 1000.0;'
        '            if (Fan(dev, out v) == 0) fan = v;'
        '            MemInfo m;'
        '            if (Mem(dev, out m) == 0) { vu = Math.Round(m.Used / 1048576.0); vt = Math.Round(m.Total / 1048576.0); }'
        '        } catch { }'
        '        return new double[] { gpu, clk, mclk, tmp, pwr, fan, vu, vt };'
        '    }'
        '    // 最大频率, PCIe代, PCIe宽度, 降频原因位掩码, 功耗墙W'
        '    public static double[] Extra() {'
        '        if (dev == IntPtr.Zero) return null;'
        '        double ck = -1, pg = -1, pw = -1, th = -1, lm = -1;'
        '        try {'
        '            uint v;'
        '            if (MaxClock(dev, 0, out v) == 0) ck = v;'
        '            if (PcieGen(dev, out v) == 0) pg = v;'
        '            if (PcieWidth(dev, out v) == 0) pw = v;'
        '            ulong m;'
        '            if (Throttle(dev, out m) == 0) th = (double)m;'
        '            if (EnfLimit(dev, out v) == 0) lm = v / 1000.0;'
        '        } catch { }'
        '        return new double[] { ck, pg, pw, th, lm };'
        '    }'
        '}'
    ) -join "`n"
    try { Add-Type -TypeDefinition $nvcs -Language CSharp -ErrorAction Stop } catch { }
}
if ('NvGpu' -as [type]) { try { $gpuUseNvml = [NvGpu]::Start() } catch { $gpuUseNvml = $false } }
    $script:t0 = Get-Date
    $cols = @('timestamp_utc', 'gpu_temp_c', 'gpu_util_pct', 'gpu_mem_used_mb', 'proc_vram_mb', 'proc_ram_mb',
              'gpu_clock_mhz', 'gpu_mem_clock_mhz', 'gpu_clock_max_mhz', 'gpu_power_w', 'gpu_fan_pct',
              'pcie_gen', 'pcie_width', 'cpu_util_pct', 'cpu_max_core_pct', 'cpu_temp_c',
              'proc_cpu_pct', 'sys_ram_pct', 'sys_ram_avail_mb', 'sys_commit_mb', 'shared_vram_mb',
              'gpu_limit_w', 'ac_online', 'battery_pct', 'cpu_pkg_w',
              'thr_sw_power_cap', 'thr_sw_thermal', 'thr_hw_thermal', 'thr_hw_slowdown', 'thr_sync_boost',
              'thr_gpu_idle', 'thr_app_clocks', 'thr_hw_power_brake')
    ($cols -join ',') | Out-File -FilePath $csv -Encoding ASCII

    $baseQ = 'temperature.gpu,utilization.gpu,memory.used'
    $extQ  = $baseQ + ',clocks.current.graphics,clocks.current.memory,clocks.max.graphics,power.draw,fan.speed,pcie.link.gen.current,pcie.link.width.current,' +
             'clocks_throttle_reasons.sw_power_cap,clocks_throttle_reasons.sw_thermal_slowdown,clocks_throttle_reasons.hw_thermal_slowdown,' +
             'clocks_throttle_reasons.hw_slowdown,clocks_throttle_reasons.sync_boost,clocks_throttle_reasons.gpu_idle,' +
             'clocks_throttle_reasons.applications_clocks_setting,clocks_throttle_reasons.hw_power_brake_slowdown'
    $extOk = $null          # $null = 还没探测；false = 这台机器的 nvidia-smi 不支持扩展字段

    # ---- 供电侧：AC 状态 / 电池（GetSystemPowerStatus，零依赖、每 tick 一次几乎没有开销）----
    # 台机没有电池 → BatteryFlag 的 128 位会置位，电量读 255（未知），这些都不当错误处理。
    if (-not ('PerfPower' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PerfPower {
    [StructLayout(LayoutKind.Sequential)]
    public struct SPS {
        public byte ACLineStatus; public byte BatteryFlag; public byte BatteryLifePercent;
        public byte SystemStatusFlag; public int BatteryLifeTime; public int BatteryFullLifeTime;
    }
    [DllImport("kernel32.dll")] public static extern bool GetSystemPowerStatus(out SPS s);
    public static int[] Read() {
        SPS s;
        if (!GetSystemPowerStatus(out s)) return null;
        return new int[] { s.ACLineStatus, s.BatteryFlag, s.BatteryLifePercent, s.SystemStatusFlag };
    }
}
'@ -ErrorAction SilentlyContinue
    }
    $powerEvOk = $false
    $limitOk = $null        # $null = 还没探测；false = 这台机器的 nvidia-smi 没有 enforced.power.limit
    $lastLimit = 'NA'
    # ---- CPU 封装功耗：只读 Windows 已暴露的 PDH 计数器（Energy Meter / rapl_package0_pkg）----
    # 不装驱动、不提权、不碰游戏进程。平台不提供这个计数器集时永久关掉该字段，不报错、不退化成估算。
    $cpuPwr = $null
    $cpuPwrOk = $false
    if ($wantCpuPower) {
        try {
            $cpuPwr = New-Object System.Diagnostics.PerformanceCounter('Energy Meter', 'power', 'rapl_package0_pkg')
            [void]$cpuPwr.NextValue()                 # 速率型计数器第一次读数恒为 0，先预热
            Start-Sleep -Milliseconds 300
            [void]$cpuPwr.NextValue()
            $cpuPwrOk = $true
        } catch { $cpuPwrOk = $false; $cpuPwr = $null }
    }
    $tick = 0
    while (((Get-Date) - $script:t0).TotalSeconds -lt $maxSec) {
        $ts = (Get-Date).ToString('HH:mm:ss')
        $v = @{}
        foreach ($k in $cols) { $v[$k] = 'NA' }
        $v['timestamp_utc'] = $ts
        # ---- 供电侧采样（每 tick）----
        try {
            $pw = [PerfPower]::Read()
            if ($pw) {
                if ($pw[0] -eq 0 -or $pw[0] -eq 1) { $v['ac_online'] = $pw[0] }
                if ($pw[2] -ne 255) { $v['battery_pct'] = $pw[2] }
            }
        } catch { }

        # ---- 显卡功耗上限（enforced.power.limit）：每 5 个 tick 探一次，旧驱动没这字段就永久关掉 ----
        if ((Test-Path $smi) -and $limitOk -ne $false -and -not $gpuUseNvml -and ($tick % 5) -eq 0) {
            try {
                $lq = & $smi --query-gpu=enforced.power.limit --format=csv,noheader,nounits 2>$null
                $ltext = ([string]$lq).Trim()
                $lnum = 0.0
                if ($ltext -and [double]::TryParse($ltext, [ref]$lnum) -and $lnum -gt 0) {
                    $limitOk = $true
                    $lastLimit = $lnum
                } else {
                    $limitOk = $false
                }
            } catch { $limitOk = $false }
        }
        if ($lastLimit -ne 'NA') { $v['gpu_limit_w'] = $lastLimit }
        # ---- CPU 封装功耗（计数器单位 mW → W）----
        if ($cpuPwrOk) {
            try {
                $cw = [double]$cpuPwr.NextValue() / 1000.0
                if ($cw -gt 0 -and $cw -lt 2000) { $v['cpu_pkg_w'] = [math]::Round($cw, 1) }
            } catch { $cpuPwrOk = $false }
        }
        # 温度与占用：优先 NVML（<1 ms），失败再回退 nvidia-smi（45–60 ms 进程启动）
        $gpuDone = $false
        if ($wantGpu -and $gpuUseNvml) {
            try {
                $ns = [NvGpu]::Sample()
                $ne = [NvGpu]::Extra()
                if ($ns -and $ns[0] -ge 0) {
                    $v['gpu_temp_c'] = [math]::Round($ns[3], 1)
                    $v['gpu_util_pct'] = [math]::Round($ns[0], 0)
                    $v['gpu_mem_used_mb'] = [math]::Round($ns[6], 0)
                    if ($ns[1] -ge 0) { $v['gpu_clock_mhz'] = [math]::Round($ns[1], 0) }
                    if ($ns[2] -ge 0) { $v['gpu_mem_clock_mhz'] = [math]::Round($ns[2], 0) }
                    if ($ns[4] -ge 0) { $v['gpu_power_w'] = [math]::Round($ns[4], 2) }
                    if ($ns[5] -ge 0) { $v['gpu_fan_pct'] = [math]::Round($ns[5], 0) }
                    if ($ne) {
                        if ($ne[0] -ge 0) { $v['gpu_clock_max_mhz'] = [math]::Round($ne[0], 0) }
                        if ($ne[1] -ge 0) { $v['pcie_gen'] = [math]::Round($ne[1], 0) }
                        if ($ne[2] -ge 0) { $v['pcie_width'] = [math]::Round($ne[2], 0) }
                        if ($ne[3] -ge 0) {
                            # NVML 位掩码 → 与 nvidia-smi 相同的 Active / Not Active 文案
                            # （下游按 ^Active$ 计数，格式必须一致）
                            # 0x1 GpuIdle / 0x2 AppClocks / 0x4 SwPowerCap / 0x8 HwSlowdown
                            # 0x10 SyncBoost / 0x20 SwThermal / 0x40 HwThermal / 0x80 HwPowerBrake
                            $m = [int64]$ne[3]
                            $v['thr_gpu_idle']       = $(if (($m -band 0x1) -ne 0) { 'Active' } else { 'Not Active' })
                            $v['thr_app_clocks']     = $(if (($m -band 0x2) -ne 0) { 'Active' } else { 'Not Active' })
                            $v['thr_sw_power_cap']   = $(if (($m -band 0x4) -ne 0) { 'Active' } else { 'Not Active' })
                            $v['thr_hw_slowdown']    = $(if (($m -band 0x8) -ne 0) { 'Active' } else { 'Not Active' })
                            $v['thr_sync_boost']     = $(if (($m -band 0x10) -ne 0) { 'Active' } else { 'Not Active' })
                            $v['thr_sw_thermal']     = $(if (($m -band 0x20) -ne 0) { 'Active' } else { 'Not Active' })
                            $v['thr_hw_thermal']     = $(if (($m -band 0x40) -ne 0) { 'Active' } else { 'Not Active' })
                            $v['thr_hw_power_brake'] = $(if (($m -band 0x80) -ne 0) { 'Active' } else { 'Not Active' })
                        }
                        if ($ne[4] -ge 0) { $v['gpu_limit_w'] = [math]::Round($ne[4], 1) }
                    }
                    $gpuDone = $true
                }
            } catch { $gpuDone = $false }
        }
        if (-not $gpuDone -and $wantGpu -and (Test-Path $smi)) {
            try {
                $p = $null
                if ($extOk -ne $false) {
                    $q = & $smi --query-gpu=$extQ --format=csv,noheader,nounits 2>$null
                    if ($q -and $LASTEXITCODE -eq 0) { $p = @($q -split ',' | ForEach-Object { $_.Trim() }); $extOk = $true }
                    elseif ($extOk -eq $null) { $extOk = $false }
                }
                if (-not $p) {
                    $q = & $smi --query-gpu=$baseQ --format=csv,noheader,nounits 2>$null
                    if ($q) { $p = @($q -split ',' | ForEach-Object { $_.Trim() }) }
                }
                if ($p -and $p.Count -ge 3) {
                    $v['gpu_temp_c'] = $p[0]; $v['gpu_util_pct'] = $p[1]; $v['gpu_mem_used_mb'] = $p[2]
                    if ($p.Count -ge 18) {
                        $v['gpu_clock_mhz']     = $p[3]
                        $v['gpu_mem_clock_mhz'] = $p[4]
                        $v['gpu_clock_max_mhz'] = $p[5]
                        $v['gpu_power_w']       = $p[6]
                        $v['gpu_fan_pct']       = $p[7]
                        $v['pcie_gen']          = $p[8]
                        $v['pcie_width']        = $p[9]
                        $v['thr_sw_power_cap']  = $p[10]
                        $v['thr_sw_thermal']    = $p[11]
                        $v['thr_hw_thermal']    = $p[12]
                        $v['thr_hw_slowdown']   = $p[13]
                        $v['thr_sync_boost']    = $p[14]
                        $v['thr_gpu_idle']      = $p[15]
                        $v['thr_app_clocks']    = $p[16]
                        $v['thr_hw_power_brake']= $p[17]
                    }
                }
            } catch { }
        }
        $vram = 'NA'
        if ($wantVram) {
            try {
                $c = Get-Counter -Counter ("\GPU Process Memory(pid_" + $gpid + "*)\Local Usage") -ErrorAction SilentlyContinue
                if ($c -and $c.CounterSamples.Count -gt 0) {
                    $vram = [math]::Round((($c.CounterSamples | Measure-Object -Property CookedValue -Sum).Sum) / 1MB, 0)
                }
            } catch { }
        }
        $v['proc_vram_mb'] = $vram
        $ram = 'NA'
        if ($wantRam) {
            try { $pr = Get-Process -Id $gpid -ErrorAction Stop; $ram = [math]::Round($pr.WorkingSet64 / 1MB, 0) } catch { }
        }
        $v['proc_ram_mb'] = $ram
        # CPU 每核占用：2 s 一采（CIM 单次约 0.3 s，1 s 一采会吃掉 1/3 的采样周期），中间秒沿用上次值
        if (($tick % 2) -eq 0) {
            try {
                $all = @(Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -ErrorAction Stop)
                $total = @($all | Where-Object { $_.Name -eq '_Total' })
                $cores = @($all | Where-Object { $_.Name -ne '_Total' } | ForEach-Object { [double]$_.PercentProcessorTime })
                if ($total.Count -gt 0) { $script:cpuTotal = [math]::Round([double]$total[0].PercentProcessorTime, 1) }
                if ($cores.Count -gt 0) { $script:cpuMaxCore = [math]::Round(($cores | Measure-Object -Maximum).Maximum, 1) }
            } catch { }
        }
        if ($null -ne $script:cpuTotal)   { $v['cpu_util_pct'] = $script:cpuTotal }
        if ($null -ne $script:cpuMaxCore) { $v['cpu_max_core_pct'] = $script:cpuMaxCore }
        # CPU 温度：厂商固件通道（当前仅联想）。读不到就保持 NA，
        # 绝不用「CPU 利用率换算」「ACPI 热区」之类顶替（规则文档 §2 / §3.3）。
        if ($collectCpuTemp -and (Get-Command Get-VendorCpuTempSnapshot -ErrorAction SilentlyContinue)) {
            try {
                $vt = Get-VendorCpuTempSnapshot
                if ($vt -and $vt.ok -and $null -ne $vt.value) { $v['cpu_temp_c'] = [int]$vt.value }
            } catch { }
        }
        # ---- B1 新增遥测：进程 CPU / 系统内存 / 提交量 / 共享显存 ----
        # 进程 CPU：用 TotalProcessorTime 差分，避开「性能计数器对象名本地化」的坑
        if ($wantProcCpu) {
        try {
            $pr2 = Get-Process -Id $gpid -ErrorAction Stop
            $nowCpu = $pr2.TotalProcessorTime.TotalMilliseconds
            $nowWall = [DateTime]::Now
            if ($null -ne $script:lastProcCpu -and $nowWall -gt $script:lastProcWall) {
                $dt = ($nowWall - $script:lastProcWall).TotalMilliseconds
                if ($dt -gt 100) {
                    $cores = [math]::Max(1, [Environment]::ProcessorCount)
                    $pct = 100.0 * ($nowCpu - $script:lastProcCpu) / ($dt * $cores)
                    $v['proc_cpu_pct'] = [math]::Round([math]::Max(0.0, [math]::Min(100.0 * $cores, $pct)), 1)
                }
            }
            $script:lastProcCpu = $nowCpu
            $script:lastProcWall = $nowWall
        } catch { }
        }
        # 系统内存 / 可用 / 提交量：GlobalMemoryStatusEx（原生，不走本地化计数器）
        if (($tick % 2) -eq 0) {
            try {
                if (-not ('PerfMem' -as [type])) {
                    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PerfMem {
    [StructLayout(LayoutKind.Sequential)] public struct MS {
        public uint len; public uint load; public ulong totalPhys; public ulong availPhys;
        public ulong totalPage; public ulong availPage; public ulong totalVirt; public ulong availVirt;
        public ulong availExt; }
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GlobalMemoryStatusEx(ref MS b);
    public static ulong[] Read() {
        MS m = new MS(); m.len = (uint)Marshal.SizeOf(typeof(MS));
        if (!GlobalMemoryStatusEx(ref m)) return null;
        return new ulong[] { m.totalPhys, m.availPhys, m.totalPage, m.availPage };
    }
}
'@ -ErrorAction SilentlyContinue
                }
                $mm = [PerfMem]::Read()
                if ($mm) {
                    if ($mm[0] -gt 0) {
                        $script:sysRamPct = [math]::Round(100.0 * ($mm[0] - $mm[1]) / $mm[0], 1)
                    }
                    $script:sysRamAvail = [math]::Round($mm[1] / 1MB, 0)
                    $script:sysCommit = [math]::Round(($mm[2] - $mm[3]) / 1MB, 0)
                }
            } catch { }
            # 共享 GPU 内存：只取「目标游戏所在的那张卡」，不跨适配器求和（求和会把核显/虚拟适配器一起算进来）
            # 取值链（已实测）：GPU Process Memory(pid_<游戏>_luid_0xAAAA_0xBBBB_phys_N) → 拼出适配器实例名
            #                  → \GPU Adapter Memory(luid_...)\Shared Usage
            # 拿不到就保持 NA（绝不填 0）；适配器实例会随进程消失，出错时清缓存下轮重解析。
            if ($wantShared) {
                try {
                    if (-not $script:sharedPc) {
                        $luids = @()
                        $pcat = New-Object System.Diagnostics.PerformanceCounterCategory('GPU Process Memory')
                        foreach ($pi in $pcat.GetInstanceNames()) {
                            if ($pi -match ('^pid_' + $gpid + '_luid_0x([0-9A-Fa-f]+)_0x([0-9A-Fa-f]+)_phys_(\d+)$')) {
                                $luids += [pscustomobject]@{
                                    Name = 'luid_0x' + $matches[1].PadLeft(8, '0') + '_0x' + $matches[2].PadLeft(8, '0') + '_phys_' + $matches[3]
                                    Inst = $pi
                                }
                            }
                        }
                        # 多张卡都挂着这个进程时，取它显存占用最大的那张（真正的渲染卡）
                        $pick = $null
                        if ($luids.Count -gt 1) {
                            $best = -1.0
                            foreach ($l in $luids) {
                                try {
                                    $dc = New-Object System.Diagnostics.PerformanceCounter('GPU Process Memory', 'Dedicated Usage', $l.Inst)
                                    [void]$dc.NextValue(); Start-Sleep -Milliseconds 80
                                    $dv = [double]$dc.NextValue()
                                    if ($dv -gt $best) { $best = $dv; $pick = $l.Name }
                                } catch { }
                            }
                        }
                        if (-not $pick -and $luids.Count -gt 0) { $pick = $luids[0].Name }
                        if ($pick) {
                            $pcNew = New-Object System.Diagnostics.PerformanceCounter('GPU Adapter Memory', 'Shared Usage', $pick)
                            [void]$pcNew.NextValue()          # 首次取值恒为 0，必须先热身
                            $script:sharedPc = $pcNew
                        }
                    }
                    if ($script:sharedPc) {
                        $bytes = [double]$script:sharedPc.NextValue()
                        if ($bytes -ge 0) { $script:sharedVram = [math]::Round($bytes / 1MB, 0) }
                    }
                } catch {
                    $script:sharedPc = $null      # 实例消失/驱动重启：下轮重新解析
                    $script:sharedVram = $null
                }
            }
        }
        if ($wantSysMem) {
            if ($null -ne $script:sysRamPct) { $v['sys_ram_pct'] = $script:sysRamPct }
            if ($null -ne $script:sysRamAvail) { $v['sys_ram_avail_mb'] = $script:sysRamAvail }
            if ($null -ne $script:sysCommit) { $v['sys_commit_mb'] = $script:sysCommit }
        }
        if ($wantShared -and $null -ne $script:sharedVram) { $v['shared_vram_mb'] = $script:sharedVram }
        (($cols | ForEach-Object { [string]$v[$_] }) -join ',') | Out-File -FilePath $csv -Append -Encoding ASCII
        $tick++
        Start-Sleep -Milliseconds 1000
    }
}

# ---------------------------------------------------------------- foreground helper
if (-not ('PerfW32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class PerfW32 {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    [DllImport("shcore.dll")] public static extern int GetProcessDpiAwareness(IntPtr h, out int v);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@
}
function Get-ForegroundPid {
    try {
        $h = [PerfW32]::GetForegroundWindow()
        if ($h -eq [IntPtr]::Zero) { return 0 }
        [uint32]$fp = 0
        [void][PerfW32]::GetWindowThreadProcessId($h, [ref]$fp)
        return [int]$fp
    } catch { return 0 }
}
$consoleHwnd = [PerfW32]::GetConsoleWindow()
function Hide-Console { if ($consoleHwnd -ne [IntPtr]::Zero) { [void][PerfW32]::ShowWindow($consoleHwnd, 6) } }
function Show-Console { if ($consoleHwnd -ne [IntPtr]::Zero) { [void][PerfW32]::ShowWindow($consoleHwnd, 9) } }

# ---------------------------------------------------------------- countdown + focus game
if ($Countdown -gt 0) {
    Write-Host ''
    Write-Host ('Starting in ' + $Countdown + ' s - switch back to the game window now.') -ForegroundColor Yellow
    for ($c = $Countdown; $c -ge 1; $c--) {
        Write-Host -NoNewline ('  ' + $c + ' ')
        Start-Sleep -Seconds 1
    }
    Write-Host ''
    Hide-Console
}
# 采集前把游戏窗口拉回前台：游戏失焦会停止/降频出帧，导致只采到一两秒数据
if ($game.MainWindowHandle -ne 0) {
    try {
        [void][PerfW32]::ShowWindow($game.MainWindowHandle, 9)
        [void][PerfW32]::SetForegroundWindow($game.MainWindowHandle)
        Write-Host 'Game window brought to foreground.' -ForegroundColor DarkGray
    } catch { }
    Start-Sleep -Milliseconds 800
}

# ---------------------------------------------------------------- resolution
$resW = 0; $resH = 0; $monW = 0; $monH = 0
$winMode = ''
try {
    $hwndGame = $game.MainWindowHandle
    if ($collectRes -and $hwndGame -ne 0) {
        [int]$awareV = 0
        try { [void][PerfW32]::GetProcessDpiAwareness([PerfW32]::GetCurrentProcess(), [ref]$awareV) } catch { }
        $dpiScale = 1.0
        if ($awareV -eq 0) {
            $wdpi = [int][PerfW32]::GetDpiForWindow($hwndGame)
            if ($wdpi -gt 0) { $dpiScale = $wdpi / 96.0 }
        }
        $cr = New-Object PerfW32+RECT
        if ([PerfW32]::GetClientRect($hwndGame, [ref]$cr)) {
            $resW = [int][math]::Round(($cr.Right - $cr.Left) * $dpiScale)
            $resH = [int][math]::Round(($cr.Bottom - $cr.Top) * $dpiScale)
        }
        $mon = [PerfW32]::MonitorFromWindow($hwndGame, 2)
        $mi = New-Object PerfW32+MONITORINFO
        $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
        if ([PerfW32]::GetMonitorInfo($mon, [ref]$mi)) {
            $monW = [int][math]::Round(($mi.rcMonitor.Right - $mi.rcMonitor.Left) * $dpiScale)
            $monH = [int][math]::Round(($mi.rcMonitor.Bottom - $mi.rcMonitor.Top) * $dpiScale)
        }
        if ($monW -gt 0 -and [math]::Abs($resW - $monW) -le 8 -and [math]::Abs($resH - $monH) -le 8) {
            $winMode = '全屏'
            $resW = $monW
            $resH = $monH
        } elseif ($resW -gt 0) {
            $winMode = '窗口/无边框'
        }
    }
} catch { }
if ($resW -gt 0) {
    Write-Host ('Resolution: ' + $resW + ' x ' + $resH + '  (' + $winMode + ', monitor ' + $monW + 'x' + $monH + ')') -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- run PresentMon
# kill any orphan PresentMon process: a stale ETW session blocks new captures
# NVIDIA App 的 FrameViewService 会占用 ETW 内核通道，导致 PresentMon 收不到任何帧事件 -> 先停掉它
& logman stop FrameViewService -ets 2>$null | Out-Null
& logman stop "WPR" -ets 2>$null | Out-Null
Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(presentmon|PresentMon_x64)$' } | ForEach-Object { try { Stop-Process -Id $_.Id -Force } catch { } }
& logman stop PresentMon -ets 2>$null | Out-Null

$pmArgs = @('--process_id', "$GamePid", '--output_file', $pmCsv, '--v2_metrics', '--no_console_stats')
Write-Host ('Capturing ' + $Seconds + ' s ...') -ForegroundColor Green
$capStartTime = Get-Date
$pmProc = Start-Process $pmExe -ArgumentList $pmArgs -PassThru -WindowStyle Hidden

# PresentMon writes the CSV on the first captured frame.
$started = $false
for ($w = 1; $w -le 12; $w++) {
    Start-Sleep -Seconds 1
    if (Test-Path $pmCsv) { $started = $true; break }
    try { $pmProc.Refresh() } catch { }
    if ($pmProc.HasExited) { break }
}
try { $pmProc.Refresh() } catch { }
if (-not $started) {
    if (-not $pmProc.HasExited) { try { Stop-Process -Id $pmProc.Id -Force } catch { } }
    & logman stop PresentMon -ets 2>$null | Out-Null
Write-Host 'PresentMon did not capture anything.' -ForegroundColor Red
Write-Host '  - 已自动尝试停止 NVIDIA FrameViewService / WPR 的 ETW 会话；若仍失败，多半是别的追踪软件占着内核通道' -ForegroundColor Yellow
Write-Host '  - 检查: logman query -ets | findstr /i "FrameView NT Kernel WPR"' -ForegroundColor Yellow
Write-Host '  - 排障: 管理员运行  logman stop FrameViewService -ets  后再试一次' -ForegroundColor Yellow
    Pause-End 'Press Enter to exit'; exit 2
}

# PresentMon 2.6 ignores --timed, so the duration is enforced here.
$left = $Seconds - ($w - 1)
if ($left -lt 1) { $left = 1 }
$fgHits = 0
$fgSamples = 0
$lastSize = 0
$idleCount = 0
$wallSec = 0
$stalled = $false
for ($s = 1; $s -le $left; $s++) {
    Start-Sleep -Seconds 1
    $wallSec = $s
    $fgSamples++
    if ((Get-ForegroundPid) -eq $GamePid) { $fgHits++ }
    $sizeNow = 0
    try { $sizeNow = (Get-Item $pmCsv -ErrorAction Stop).Length } catch { }
    if ($sizeNow -gt $lastSize) { $lastSize = $sizeNow; $idleCount = 0 } else { $idleCount++ }
    if ($idleCount -ge 8) {
        $stalled = $true
        Write-Host ('  [!] no new frames for ' + $idleCount + ' s - the game stopped rendering, ending early.') -ForegroundColor Yellow
        break
    }
    if (($s % 15) -eq 0) { Write-Host ('  ... ' + $s + ' / ' + $left + ' s') -ForegroundColor DarkGray }
}
try { $pmProc.Refresh() } catch { }
if (-not $pmProc.HasExited) { try { Stop-Process -Id $pmProc.Id -Force } catch { } }
Start-Sleep -Milliseconds 900
Show-Console
if ($fgSamples -gt 0) { $fgPct = [math]::Round(100.0 * $fgHits / $fgSamples, 0) } else { $fgPct = $null }

& logman stop EndfieldPerf -ets 2>$null | Out-Null
try { Wait-Job $sampler -Timeout 20 | Out-Null; Stop-Job $sampler -ErrorAction SilentlyContinue; Remove-Job $sampler -Force -ErrorAction SilentlyContinue } catch { }

# ---------------------------------------------------------------- analyse
if (-not (Test-Path $pmCsv)) {
    Write-Host 'No PresentMon CSV produced - the capture failed.' -ForegroundColor Red
    Pause-End 'Press Enter to exit'; exit 2
}

# ---------------- 供电侧：采集窗口内的电源中断 + 近 24 小时异常关机/硬件错误 ----------------
# 说明：105 = 「电源来源变化」（拔/插交流电、掉电切电池都会记）；41 / 6008 是非正常关机；
# WHEA-Logger 是硬件错误（供电/PCIe 问题会报在这里）。一律只读事件日志，不猜。
$capEndTime = Get-Date
$powerEvents = $null
try {
    $ev105 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 105; StartTime = $capStartTime; EndTime = $capEndTime } -ErrorAction SilentlyContinue)
    $powerEvents = $ev105.Count
} catch { $powerEvents = $null }
$powerHealth = $null
$powerHealthDetail = $null
try {
    $since24 = (Get-Date).AddHours(-24)
    $evBad  = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 6008; StartTime = $since24 } -ErrorAction SilentlyContinue)
    $evWhea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since24 } -ErrorAction SilentlyContinue)
    $powerHealth = if (($evBad.Count + $evWhea.Count) -eq 0) { 'ok' } else { 'events' }
    $powerHealthDetail = '非正常关机 ' + $evBad.Count + ' 次 · 硬件错误 ' + $evWhea.Count + ' 条'
} catch {
    $powerHealth = $null
    $powerHealthDetail = $null
}
$frameTimes = New-Object System.Collections.Generic.List[double]
$dispLat    = New-Object System.Collections.Generic.List[double]
$inLat      = New-Object System.Collections.Generic.List[double]
$ftRows     = New-Object System.Collections.Generic.List[object]   # 帧时间 + 该帧的起点时刻（CPUStartTime，用于预热丢弃与按秒分桶）
$dispTimes  = New-Object System.Collections.Generic.List[double]   # 上屏时刻（DisplayedTime），用来看「呈现 → 上屏」这一层
$syncHist   = @{}      # SyncInterval 取值分布（0 = 不等待垂直同步）
$flagsHist  = @{}      # PresentFlags 取值分布（0x200 = 允许撕裂）
$allowTearN = 0
$rowN       = 0
# 批次 B1：把 v2 CSV 里其余逐帧列也吃进来（GPU Busy / CPU 帧处理 / GPU 渲染 / 等待）
$cpuBusy    = New-Object System.Collections.Generic.List[double]
$gpuTime    = New-Object System.Collections.Generic.List[double]
$gpuBusy    = New-Object System.Collections.Generic.List[double]
$gpuWait    = New-Object System.Collections.Generic.List[double]

# Robust CSV read: the file may end with a partially written line after the kill.
$csvLines = @(Get-Content -Path $pmCsv -ErrorAction Stop)
if ($csvLines.Count -lt 2) {
    Write-Host 'PresentMon CSV is empty.' -ForegroundColor Red
    Pause-End 'Press Enter to exit'; exit 2
}
$hdr = $csvLines[0] -split ','
$colCount = $hdr.Count
$iPid = [array]::IndexOf($hdr, 'ProcessID')
$iApp = [array]::IndexOf($hdr, 'Application')
$iFt  = [array]::IndexOf($hdr, 'FrameTime')
$iDl  = [array]::IndexOf($hdr, 'DisplayLatency')
$iCl  = [array]::IndexOf($hdr, 'ClickToPhotonLatency')
$iRt  = [array]::IndexOf($hdr, 'PresentRuntime')
$iPm  = [array]::IndexOf($hdr, 'PresentMode')
$iOns = [array]::IndexOf($hdr, 'CPUStartTime')
$iDsp = [array]::IndexOf($hdr, 'DisplayedTime')
$iSyn = [array]::IndexOf($hdr, 'SyncInterval')
$iFlg = [array]::IndexOf($hdr, 'PresentFlags')
$iAlw = [array]::IndexOf($hdr, 'AllowsTearing')
$iCb  = [array]::IndexOf($hdr, 'CPUBusy')
$iGt  = [array]::IndexOf($hdr, 'GPUTime')
$iGb  = [array]::IndexOf($hdr, 'GPUBusy')
$iGw  = [array]::IndexOf($hdr, 'GPUWait')

for ($ln = 1; $ln -lt $csvLines.Count; $ln++) {
    $f = $csvLines[$ln] -split ','
    if ($f.Count -ne $colCount) { continue }
    $isMe = $false
    if ($iPid -ge 0 -and $f[$iPid] -eq "$GamePid") { $isMe = $true }
    if (-not $isMe -and $iApp -ge 0 -and $f[$iApp] -eq ($exeBase + '.exe')) { $isMe = $true }
    if (-not $isMe) { continue }
    $rowN++
    $onset = $null
    if ($iOns -ge 0) { $o = 0.0; if ([double]::TryParse($f[$iOns], [ref]$o)) { $onset = $o } }
    if ($iFt -ge 0) {
        $ft = 0.0
        if ([double]::TryParse($f[$iFt], [ref]$ft) -and $ft -gt 0) { $ftRows.Add([pscustomobject]@{ onset = $onset; ft = $ft }) }
    }
    if ($iDl -ge 0) {
        $dl = 0.0
        if ([double]::TryParse($f[$iDl], [ref]$dl) -and $dl -gt 0) { $dispLat.Add($dl) }
    }
    if ($iCb -ge 0) { $cb = 0.0; if ([double]::TryParse($f[$iCb], [ref]$cb) -and $cb -ge 0) { $cpuBusy.Add($cb) } }
    if ($iGt -ge 0) { $gt = 0.0; if ([double]::TryParse($f[$iGt], [ref]$gt) -and $gt -ge 0) { $gpuTime.Add($gt) } }
    if ($iGb -ge 0) { $gb = 0.0; if ([double]::TryParse($f[$iGb], [ref]$gb) -and $gb -ge 0) { $gpuBusy.Add($gb) } }
    if ($iGw -ge 0) { $gw = 0.0; if ([double]::TryParse($f[$iGw], [ref]$gw) -and $gw -ge 0) { $gpuWait.Add($gw) } }
    if ($iCl -ge 0) {
        $cl = 0.0
        if ([double]::TryParse($f[$iCl], [ref]$cl) -and $cl -gt 0) { $inLat.Add($cl) }
    }
    if ($iDsp -ge 0) {
        $dt = 0.0
        if ([double]::TryParse($f[$iDsp], [ref]$dt) -and $dt -gt 0) { $dispTimes.Add($dt) }
    }
    if ($iSyn -ge 0) { $k = $f[$iSyn]; if ($k) { if ($syncHist.ContainsKey($k)) { $syncHist[$k]++ } else { $syncHist[$k] = 1 } } }
    if ($iFlg -ge 0) { $k = $f[$iFlg]; if ($k) { if ($flagsHist.ContainsKey($k)) { $flagsHist[$k]++ } else { $flagsHist[$k] = 1 } } }
    if ($iAlw -ge 0 -and $f[$iAlw] -eq '1') { $allowTearN++ }
}

# 预热丢弃：按 CPUStartTime 去掉开头 WarmupSec 秒的帧；没有该列时按帧时间累加近似
$warmupDropped = 0
if ($WarmupSec -gt 0 -and $ftRows.Count -gt 0) {
    $o0 = $ftRows[0].onset
    if ($null -ne $o0) {
        $cut = $o0 + $WarmupSec * 1000.0
        while ($ftRows.Count -gt 0 -and $null -ne $ftRows[0].onset -and $ftRows[0].onset -lt $cut) { $ftRows.RemoveAt(0); $warmupDropped++ }
    } else {
        $acc = 0.0
        while ($ftRows.Count -gt 0 -and $acc -lt $WarmupSec * 1000.0) { $acc += $ftRows[0].ft; $ftRows.RemoveAt(0); $warmupDropped++ }
    }
}
$onsets = New-Object System.Collections.Generic.List[double]
foreach ($r in $ftRows) { $frameTimes.Add($r.ft); if ($null -ne $r.onset) { $onsets.Add($r.onset) } }

function Get-Stat($list) {
    if ($null -eq $list -or $list.Count -eq 0) { return $null }
    $m = $list | Measure-Object -Average -Maximum -Minimum
    return [pscustomobject]@{ Avg = $m.Average; Max = $m.Maximum; Min = $m.Minimum; N = $list.Count }
}
function Get-Percentile($list, [double]$p) {
    if ($null -eq $list -or $list.Count -eq 0) { return $null }
    $arr = @($list | Sort-Object)
    $idx = [math]::Ceiling($arr.Count * $p) - 1
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $arr.Count) { $idx = $arr.Count - 1 }
    return $arr[$idx]
}

if ($frameTimes.Count -lt 10) {
    Write-Host ("Too few frames captured (" + $frameTimes.Count + "). Is the game in the foreground and rendering?") -ForegroundColor Red
    Pause-End 'Press Enter to exit'; exit 3
}

$durSec    = ($frameTimes | Measure-Object -Sum).Sum / 1000.0
$avgFT     = ($frameTimes | Measure-Object -Average).Average
$avgFPS    = if ($avgFT -gt 0) { 1000.0 / $avgFT } else { 0 }
$maxFPS    = 1000.0 / ($frameTimes | Measure-Object -Minimum).Minimum
$sorted    = @($frameTimes | Sort-Object -Descending)
# ---- 1% Low / 0.1% Low（B1 统一口径）------------------------------------
# 只有一个定义：全部帧时间降序 → 取最差 N% 帧 → 求平均帧时间 → 1000/平均 = 低帧率。
# **不再丢弃最差那一帧**（1.5.x 这么做会把低值系统性抬高，也是 190.4 / 657 那种口径混乱的源头之一）。
function Get-LowFps {
    param([double[]]$SortedDesc, [double]$Pct)
    if (-not $SortedDesc -or $SortedDesc.Count -eq 0) { return $null }
    $n = [math]::Max(1, [int][math]::Ceiling($SortedDesc.Count * $Pct))
    $slow = ($SortedDesc | Select-Object -First $n | Measure-Object -Average).Average
    if ($slow -le 0) { return $null }
    return 1000.0 / $slow
}
$fps1Low  = Get-LowFps $sorted 0.01
$fps01Low = Get-LowFps $sorted 0.001
$ftP95    = Get-Percentile $frameTimes 0.95
$ftP99    = Get-Percentile $frameTimes 0.99
$minFPS   = 1000.0 / $sorted[0]

# ---- 卡顿（B1 统一定义）------------------------------------------------
# 单帧 > StutterMs 记一次；**相邻卡顿帧合并成一段**（同一段里不重复计数）；
# 段时长 = 段内帧时间之和；>100ms 的单帧另计「严重」。
$stutterSegments = New-Object System.Collections.Generic.List[object]
$severeCount = 0
$curStart = $null; $curDur = 0.0; $curFrames = 0
for ($fi = 0; $fi -lt $frameTimes.Count; $fi++) {
    $v = $frameTimes[$fi]
    if ($v -gt $StutterMs) {
        if ($v -gt 100.0) { $severeCount++ }
        if ($null -eq $curStart) { $curStart = $fi }
        $curDur += $v
        $curFrames++
    } elseif ($null -ne $curStart) {
        $stutterSegments.Add([pscustomobject]@{ start = $curStart; frames = $curFrames; ms = [math]::Round($curDur, 1) })
        $curStart = $null; $curDur = 0.0; $curFrames = 0
    }
}
if ($null -ne $curStart) { $stutterSegments.Add([pscustomobject]@{ start = $curStart; frames = $curFrames; ms = [math]::Round($curDur, 1) }) }
$stutterCount = $stutterSegments.Count
$stutterTotalMs = 0.0
foreach ($s in $stutterSegments) { $stutterTotalMs += $s.ms }
$stutterWorstMs = 0.0
foreach ($s in $stutterSegments) { if ($s.ms -gt $stutterWorstMs) { $stutterWorstMs = $s.ms } }
$stutterTop = @($stutterSegments | Sort-Object -Property ms -Descending | Select-Object -First 5)

# ---- 瓶颈相关（B1：同一次 CSV，零额外开销）------------------------------
$stCpuBusy = Get-Stat $cpuBusy
$stGpuTime = Get-Stat $gpuTime
$stGpuBusy = Get-Stat $gpuBusy
$stGpuWait = Get-Stat $gpuWait
$gpuBusyPct = $null
if ($stGpuBusy -and $avgFT -gt 0) { $gpuBusyPct = [math]::Round(100.0 * $stGpuBusy.Avg / $avgFT, 1) }
$cpuBusyMs = if ($stCpuBusy) { [math]::Round($stCpuBusy.Avg, 2) } else { $null }
$gpuRenderMs = if ($stGpuTime) { [math]::Round($stGpuTime.Avg, 2) } else { $null }
$gpuWaitMs = if ($stGpuWait) { [math]::Round($stGpuWait.Avg, 2) } else { $null }

# ---- 帧时间分布（批次 C）------------------------------------------------
$ftP999    = Get-Percentile $frameTimes 0.999
$ftMedian  = Get-Percentile $frameTimes 0.5
# 最慢一帧：曲线纵轴要能容下它，卡顿那行也要拿它解释「为什么 0 次卡顿」
$ftMax = [double](($frameTimes | Measure-Object -Maximum).Maximum)
# 抖动：帧时间的标准差（越小越稳）+ 变异系数（std / 平均，跨帧率可比）
$ftStd = $null; $ftStdPct = $null
if ($frameTimes.Count -gt 1 -and $avgFT -gt 0) {
    $sumSq = 0.0
    foreach ($v in $frameTimes) { $d = $v - $avgFT; $sumSq += $d * $d }
    $ftStd = [math]::Sqrt($sumSq / $frameTimes.Count)
    $ftStdPct = 100.0 * $ftStd / $avgFT
}
# 长帧分桶：相对中位（2× / 4×）看「卡一下」的量级，绝对阈值（>50 / >100 ms）看能不能被感知
$thr2x = $ftMedian * 2.0; $thr4x = $ftMedian * 4.0
$long2x = 0; $long4x = 0; $long50 = 0; $long100 = 0
foreach ($v in $frameTimes) {
    if ($v -gt $thr2x)  { $long2x++ }
    if ($v -gt $thr4x)  { $long4x++ }
    if ($v -gt 50.0)    { $long50++ }
    if ($v -gt 100.0)   { $long100++ }
}
$longPct = if ($frameTimes.Count -gt 0) { [math]::Round(100.0 * $long2x / $frameTimes.Count, 2) } else { 0 }

# ---- 呈现 → 上屏（同一层数据的第二个视角）--------------------------------
# 重复帧：两帧落在同一个上屏时刻，说明上屏没刷新（垂直同步/限帧/合成器重复刷新）
$repeatFrames = 0
$dispDeltaSum = 0.0; $dispDeltaN = 0
if ($dispTimes.Count -gt 1) {
    for ($i = 1; $i -lt $dispTimes.Count; $i++) {
        $d = $dispTimes[$i] - $dispTimes[$i - 1]
        if ([math]::Abs($d) -lt 0.001) { $repeatFrames++ }
        elseif ($d -gt 0) { $dispDeltaSum += $d; $dispDeltaN++ }
    }
}
$dispIntervalAvg = if ($dispDeltaN -gt 0) { $dispDeltaSum / $dispDeltaN } else { $null }
$displayedFps    = if ($dispIntervalAvg -and $dispIntervalAvg -gt 0) { 1000.0 / $dispIntervalAvg } else { $null }
$repeatPct       = if ($dispTimes.Count -gt 1) { [math]::Round(100.0 * $repeatFrames / ($dispTimes.Count - 1), 2) } else { $null }

# SyncInterval / PresentFlags：取出现最多的那个值（游戏中途改设置会让分布变宽，这里报主值 + 分布宽度）
function Get-ModeKey($hist) {
    if (-not $hist -or $hist.Count -eq 0) { return $null }
    $best = $null; $bestN = -1
    foreach ($k in $hist.Keys) { if ($hist[$k] -gt $bestN) { $bestN = $hist[$k]; $best = $k } }
    return $best
}
$syncMode  = Get-ModeKey $syncHist
$flagsMode = Get-ModeKey $flagsHist
$syncDistinct  = if ($syncHist.Count)  { $syncHist.Count }  else { 0 }
$flagsDistinct = if ($flagsHist.Count) { $flagsHist.Count } else { 0 }
$allowTearPct  = if ($rowN -gt 0) { [math]::Round(100.0 * $allowTearN / $rowN, 1) } else { $null }

# ---- 1% Low 第二口径：按 1 秒窗口的帧率序列取最差 1% ----------------------
# 口径 A（上面 $fps1Low）= 最差 1% 的**帧**的平均帧率；口径 B = 最差 1% 的**秒**的平均帧率。
# 两者差别正是「偶发一次尖峰」与「持续掉一段」的区别。
$fps1LowTime = $null; $fps1LowTimeRatio = $null; $secBins = 0
if ($onsets.Count -gt 2 -and $onsets.Count -eq $frameTimes.Count) {
    $binIdx = New-Object System.Collections.Generic.List[int]
    $o0 = $onsets[0]
    $lastBin = -1
    foreach ($o in $onsets) {
        $b = [int][math]::Floor(($o - $o0) / 1000.0)
        $binIdx.Add($b); if ($b -gt $lastBin) { $lastBin = $b }
    }
    if ($lastBin -ge 3) {
        $counts = New-Object 'int[]' ($lastBin + 1)
        foreach ($b in $binIdx) { if ($b -ge 0 -and $b -le $lastBin) { $counts[$b]++ } }
        # 首末两桶可能不满 1 秒，剔除以免把「半秒」当成低帧率
        $full = @()
        for ($b = 1; $b -lt $lastBin; $b++) { $full += [double]$counts[$b] }
        if ($full.Count -ge 5) {
            $secBins = $full.Count
            $sortedSec = @($full | Sort-Object)                 # 升序：最差在前
            $nSec = [math]::Max(1, [int][math]::Ceiling($sortedSec.Count * 0.01))
            $worstSec = ($sortedSec | Select-Object -First $nSec | Measure-Object -Average).Average
            $fps1LowTime = $worstSec                             # 1 秒桶里的帧数 = 该秒的 FPS
            if ($avgFPS -gt 0) { $fps1LowTimeRatio = [math]::Round(100.0 * $fps1LowTime / $avgFPS, 1) }
        }
    }
}

$sensors = @()
if (Test-Path $sensCsv) { $sensors = Import-Csv $sensCsv }
function Get-SensorStat([string]$col) {
    $v = @()
    foreach ($s in $sensors) {
        $x = $s.$col
        if ($x -and $x -ne 'NA') { $d = 0.0; if ([double]::TryParse($x, [ref]$d)) { $v += $d } }
    }
    return Get-Stat $v
}
$gpuTemp    = if ($collectGpuTemp)  { Get-SensorStat 'gpu_temp_c' } else { $null }
$gpuUtil    = if ($collectGpuUsage) { Get-SensorStat 'gpu_util_pct' } else { $null }
$gpuMemUsed = if ($collectGpuUsage) { Get-SensorStat 'gpu_mem_used_mb' } else { $null }   # 整卡占用，随 GPU 占用
$procVram   = if ($collectVram) { Get-SensorStat 'proc_vram_mb' } else { $null }
$procRam    = if ($collectRam)  { Get-SensorStat 'proc_ram_mb' } else { $null }

# ---- 卡顿时刻上下文（2.1.16）：把 Top 卡顿与传感器样本按采集进度对齐 ----
# 两条流不同源、没有共同时间戳，只能按比例对齐；容差写进报告，不许说成精确对齐。
$stutterCtx = $null
if (Get-Command Get-StutterContext -ErrorAction SilentlyContinue) {
    try {
        $stutterCtx = Get-StutterContext -Segments $stutterTop -FrameTimes $frameTimes -Sensors $sensors `
            -WindowSec 2 -Top 5 -CaptureStart $capStartTime -WarmupSec $WarmupSec
    } catch {
        $stutterCtx = [ordered]@{ window_seconds = 2; tolerance_seconds = $null; items = @(); reason = 'failed' }
    }
} else {
    $stutterCtx = [ordered]@{ window_seconds = 2; tolerance_seconds = $null; items = @(); reason = 'moduleMissing' }
}

# 批次 C：GPU 时钟 / 功耗 / 风扇 / PCIe + 降频原因 + CPU 占用
$gpuClock    = if ($collectGpuUsage) { Get-SensorStat 'gpu_clock_mhz' } else { $null }
$gpuClockMax = if ($collectGpuUsage) { Get-SensorStat 'gpu_clock_max_mhz' } else { $null }
$gpuMemClock = if ($collectGpuUsage) { Get-SensorStat 'gpu_mem_clock_mhz' } else { $null }
$gpuPower    = if ($collectGpuTemp)  { Get-SensorStat 'gpu_power_w' } else { $null }
$gpuFan      = if ($collectGpuTemp)  { Get-SensorStat 'gpu_fan_pct' } else { $null }
$cpuUtil     = Get-SensorStat 'cpu_util_pct'
$cpuMaxCore  = Get-SensorStat 'cpu_max_core_pct'


# B3：显存总量（一次性查询，不进采样循环）。
# 单独调用而不是加进 $extQ：加字段会挪动所有 $p[n] 的下标，
# 一旦这台机器的驱动不支持新字段，整条扩展查询都会失败，时钟/功耗/风扇跟着一起丢。
$vramTotalMb = $null
if ((Test-Path $smi) -and $collectGpuUsage) {
    try {
        $mt = & $smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
        $d = 0.0
        if ($mt -and [double]::TryParse(([string]$mt).Trim(), [ref]$d) -and $d -gt 0) { $vramTotalMb = [math]::Round($d, 0) }
    } catch { }
}
# ---- B1：新增遥测的统计 ----
$procCpu  = if ($collectProcCpu) { Get-SensorStat 'proc_cpu_pct' } else { $null }
$sysRam   = if ($collectSysMem) { Get-SensorStat 'sys_ram_pct' } else { $null }
$sysAvail = if ($collectSysMem) { Get-SensorStat 'sys_ram_avail_mb' } else { $null }
$sysCommit = if ($collectSysMem) { Get-SensorStat 'sys_commit_mb' } else { $null }
$sharedVram = if ($collectShared) { Get-SensorStat 'shared_vram_mb' } else { $null }
$cpuPkg   = if ($collectCpuPower) { Get-SensorStat 'cpu_pkg_w' } else { $null }

# ---- CPU 温度与降频（v2.1.11）：温度走厂商固件通道（仅联想），降频走 Windows 事件日志 ----
# 2.1.12：两项都受采集项开关控制。关掉时状态是 skipped（不是 unsupported），
# 报告据此显示「未采集」而不是「暂不可用」——这两者不能混。
$cpuTemp = if ($collectCpuTemp) { Get-SensorStat 'cpu_temp_c' } else { $null }
$cpuThrottle = $null
if ($collectCpuThrottle -and (Get-Command Get-CpuThrottleSummary -ErrorAction SilentlyContinue)) {
    try { $cpuThrottle = Get-CpuThrottleSummary -Since $capStartedAt } catch { $cpuThrottle = $null }
}
$platform = $null
try { if (Get-Command Get-PlatformProfile -ErrorAction SilentlyContinue) { $platform = Get-PlatformProfile } } catch { }

# 温度状态：以「采集期间到底有没有采到」为准，不以最后一次探测为准。
$cpuTempState = 'unsupported'; $cpuTempReason = ''; $cpuTempSource = ''
if (-not $collectCpuTemp) {
    $cpuTempState = 'skipped'
} elseif ($cpuTemp) {
    $cpuTempState = 'ok'
    try { $cpuTempSource = [string](Get-VendorCpuTempSnapshot).source } catch { }
    if (-not $cpuTempSource) { $cpuTempSource = 'vendor-wmi' }
} else {
    try {
        $vs = Get-VendorCpuTempSnapshot
        if ($vs) {
            $cpuTempReason = [string]$vs.reason
            if ($vs.reason -in @('vendorNotSupported', 'vendorNoChannel', 'vendorNotImplemented', 'vendorOutOfRange')) { $cpuTempState = 'unsupported' }
            else { $cpuTempState = 'failed' }
        }
    } catch { $cpuTempState = 'failed'; $cpuTempReason = 'vendorReadFailed' }
    if (-not $cpuTempReason) { $cpuTempReason = 'vendorNotSupported' }
}
$throttleOk = [bool]($cpuThrottle -and $cpuThrottle.ok)
$throttleCount = if ($cpuThrottle) { [int]$cpuThrottle.count } else { 0 }
$throttleCores = if ($cpuThrottle) { [int]$cpuThrottle.cores } else { 0 }
$throttleMaxS = if ($cpuThrottle) { $cpuThrottle.maxSeconds } else { $null }
$throttleReason = if ($cpuThrottle) { [string]$cpuThrottle.reason } else { 'throttleLogUnavailable' }
# skipped = 用户关了开关；unavailable = 日志读不了（权限/服务）；ok = 查询成功（0 条也算 ok，表示没记录到限速）
$throttleState = if (-not $collectCpuThrottle) { 'skipped' } elseif ($throttleOk) { 'ok' } else { 'unavailable' }
if (-not $collectCpuThrottle) { $throttleReason = '' }


# 供电侧统计（都来自采样 CSV；AC 状态按样本计数，不做估算）
$acOn = 0; $acOff = 0
foreach ($s0 in $sensors) {
    $ax = [string]$s0.ac_online
    if ($ax -eq '1') { $acOn++ } elseif ($ax -eq '0') { $acOff++ }
}
$acTotal  = $acOn + $acOff
$acOffPct = if ($acTotal -gt 0) { [math]::Round(100.0 * $acOff / $acTotal, 1) } else { $null }
$powerSource = if ($acTotal -eq 0) { 'unknown' } elseif ($acOff -eq 0) { 'ac' } elseif ($acOn -eq 0) { 'battery' } else { 'mixed' }
$batteryPct = Get-SensorStat 'battery_pct'
$gpuLimit   = Get-SensorStat 'gpu_limit_w'

# 内存代数（WMI SMBIOSMemoryType）：26=DDR4 34=DDR5，其余按编号回报
$ramTypeText = $null
try {
    $pmem = Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop | Select-Object -First 1
    if ($pmem) {
        $code = [int]$pmem.SMBIOSMemoryType
        $ramTypeText = switch ($code) {
            20 { 'DDR' } 21 { 'DDR2' } 24 { 'DDR3' } 26 { 'DDR4' } 27 { 'LPDDR' } 28 { 'LPDDR2' } 29 { 'LPDDR3' }
            30 { 'LPDDR4' } 34 { 'DDR5' } 35 { 'LPDDR5' } 36 { 'LPDDR5X' }
            default { if ($code -gt 0) { 'Type ' + $code } else { $null } }
        }
    }
} catch { }

# 指标字典里的「暂不可用」清单（报告要逐条标出来，带原因键）
$naMetrics = @()
$naReasons = @{}
try {
    $dictPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'capture-metrics.json'
    if (Test-Path $dictPath) {
        $dict = Get-Content $dictPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $naMetrics = @(@($dict.metrics) | Where-Object { $_.status -eq 'na' } | ForEach-Object {
                [ordered]@{ id = [string]$_.id; name = [string]$_.nameZh; reason = [string]$_.reason }
            })
        if ($dict.reasons) {
            foreach ($rp in $dict.reasons.PSObject.Properties) { $naReasons[$rp.Name] = [string]$rp.Value.zh }
        }
    }
} catch { }

# 型号（测试环境板块要用）：CPU 走 WMI，GPU 优先 NVIDIA 适配器
$cpuModelText = $null
try {
    $c1 = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
    if ($c1 -and $c1.Name) { $cpuModelText = ([string]$c1.Name).Trim() }
} catch { }
$gpuModelText = $null
try {
    $vc = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
    $nv = @($vc | Where-Object { $_.Name -like 'NVIDIA*' })
    if ($nv.Count -gt 0) { $gpuModelText = ([string]$nv[0].Name).Trim() }
    elseif ($vc.Count -gt 0) { $gpuModelText = ([string]$vc[0].Name).Trim() }
} catch { }

# PCIe 链路：取采样里出现最多的「代数 x 通道」
$pcieText = $null
if ($sensors.Count -gt 0) {
    $ph = @{}
    foreach ($s in $sensors) {
        $g = $s.pcie_gen; $w = $s.pcie_width
        if ($g -and $g -ne 'NA' -and $w -and $w -ne 'NA') {
            $k = ('Gen' + $g + ' x' + $w)
            if ($ph.ContainsKey($k)) { $ph[$k]++ } else { $ph[$k] = 1 }
        }
    }
    $pcieText = Get-ModeKey $ph
}

# 降频原因：按「有多少比例的采样点处于该原因」统计，只保留 > 0 的
$throttle = [ordered]@{}
$thrNames = [ordered]@{
    sw_power_cap  = '功耗墙'
    sw_thermal    = '温度墙（软）'
    hw_thermal    = '温度墙（硬）'
    hw_slowdown   = '硬件降频'
    sync_boost    = '同步加速'
    gpu_idle      = 'GPU 空闲'
    app_clocks    = '应用锁频'
    hw_power_brake = '功耗刹车'
}
foreach ($k in $thrNames.Keys) {
    $col = 'thr_' + $k
    $act = 0; $seen = 0
    foreach ($s in $sensors) {
        $x = $s.$col
        if ($null -eq $x -or $x -eq '' -or $x -eq 'NA') { continue }
        $seen++
        if ($x -match '^Active$') { $act++ }
    }
    if ($seen -gt 0 -and $act -gt 0) { $throttle[$k] = [math]::Round(100.0 * $act / $seen, 1) }
}

$latStat = if ($collectLatency) { Get-Stat $dispLat } else { $null }
$latP95  = if ($collectLatency) { Get-Percentile $dispLat 0.95 } else { $null }
$inStat  = Get-Stat $inLat

# PC 延迟 = 帧生成时间 + 上屏延迟（生成好的帧 到 被看到 的全过程）
$pcLatAvg = if ($latStat) { $avgFT + $latStat.Avg } else { $null }
$pcLatP95 = if ($latP95) { $ftP95 + $latP95 } else { $null }

# 帧时间曲线数据：约 300 个时间桶，每桶取最慢帧（报告与 GUI 预览共用）
$chartMs = @(); $chartAvg = @(); $chartPerBin = 0; $chartLimit = 0; $chartOver = 0
if ($collectChart -and $frameTimes.Count -gt 2) {
    $ftP999 = [double](Get-Percentile $frameTimes 0.999)
    $ftP95b = [double](Get-Percentile $frameTimes 0.95)
    # 纵轴上限要容得下最慢一帧，否则「曲线看着平，0.1% Low 却很低」会自相矛盾。
    # 但也怕一次掉到几百毫秒把整条曲线压平 → 最多放到 P99 的 3 倍，超出的帧照实记进 over。
    $softTop = [math]::Max([math]::Max($ftP999, $ftP95b * 1.15), 8.0)
    $capTop = [math]::Max($softTop, [double]$ftP99 * 3.0)
    $chartLimit = [math]::Ceiling([math]::Min($ftMax, $capTop) * 2.0) / 2.0
    foreach ($v in $frameTimes) { if ($v -gt $chartLimit) { $chartOver++ } }
    $chartPerBin = [math]::Max(1, [int][math]::Ceiling($frameTimes.Count / 300))
    $nBin = [int][math]::Ceiling($frameTimes.Count / $chartPerBin)
    $buf = New-Object System.Collections.Generic.List[double]
    $bufAvg = New-Object System.Collections.Generic.List[double]
    for ($b = 0; $b -lt $nBin; $b++) {
        $bs = $b * $chartPerBin
        $be = [math]::Min($bs + $chartPerBin, $frameTimes.Count) - 1
        $mx = 0.0; $sum = 0.0; $cnt = 0
        for ($k = $bs; $k -le $be; $k++) {
            $v = $frameTimes[$k]
            if ($v -gt $mx) { $mx = $v }
            $sum += $v; $cnt++
        }
        # ms  = 该桶最慢帧（看卡顿尖峰）
        # avg = 该桶平均帧时间（换算成帧率才是真实帧率水平）
        $buf.Add([math]::Round($mx, 2))
        $bufAvg.Add([math]::Round($(if ($cnt -gt 0) { $sum / $cnt } else { 0 }), 2))
    }
    $chartMs = $buf.ToArray()
    $chartAvg = $bufAvg.ToArray()
}

# 数值格式化（趋势/诊断两块要用，定义提前到它们之前；下面不再重复定义）
function Fmt($v, [string]$fmt = '0.0') { if ($null -eq $v) { return 'NA' } return ([string]::Format([cultureinfo]::InvariantCulture, '{0:' + $fmt + '}', $v)) }
# ── B3：遥测趋势（CPU / GPU 负载、GPU 温度、GPU 功耗）──
# 遥测采样（约 500 ms）比帧粗得多，所以按「与帧时间图同一套时间桶」取桶内平均；
# 某个桶里一个样本都没有就留 $null —— 图上直接断开，不补值、不插值、不沿用上一个样本。
function Get-NumOrNull($v) {
    $d = 0.0
    if ([double]::TryParse([string]$v, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}
$trend = $null
if ($sensors.Count -ge 2 -and $nBin -gt 1) {
    $stamps = New-Object System.Collections.Generic.List[object]
    $t0 = $null; $t1 = $null
    foreach ($s in $sensors) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParse([string]$s.timestamp_utc, [ref]$dt)) {
            [void]$stamps.Add($dt)
            if ($null -eq $t0 -or $dt -lt $t0) { $t0 = $dt }
            if ($null -eq $t1 -or $dt -gt $t1) { $t1 = $dt }
        } else { [void]$stamps.Add($null) }
    }
    if ($null -ne $t0 -and $null -ne $t1) {
        $span = ($t1 - $t0).TotalSeconds
        if ($span -gt 0) {
            # 桶数不能照抄帧时间图：传感器样本少，分段太细会每段一个孤立点、连线画不出来。
            # 也不能一段一个样本：采样间隔有抖动，会出现「隔一段空一段」的断线。
            # 按每段约 2 个样本定段数（最多 60 段），段内仍取平均。
            $nb = [math]::Min([int]$nBin, [math]::Min(60, [math]::Max(2, [int][math]::Floor($sensors.Count / 2))))
            $tcols = @('cpu_util_pct', 'gpu_util_pct', 'gpu_temp_c', 'gpu_power_w')
            $tsum = @{}; $tcnt = @{}
            foreach ($c in $tcols) { $tsum[$c] = New-Object 'double[]' $nb; $tcnt[$c] = New-Object 'int[]' $nb }
            for ($i = 0; $i -lt $sensors.Count; $i++) {
                $dt = $stamps[$i]
                if ($null -eq $dt) { continue }
                $b = [int][math]::Floor((($dt - $t0).TotalSeconds / $span) * $nb)
                if ($b -lt 0) { $b = 0 }
                if ($b -ge $nb) { $b = $nb - 1 }
                foreach ($c in $tcols) {
                    $nv = Get-NumOrNull $sensors[$i].$c
                    if ($null -ne $nv) { $tsum[$c][$b] += $nv; $tcnt[$c][$b]++ }
                }
            }
            $trend = [ordered]@{ bins = $nb }
            foreach ($c in $tcols) {
                $arr = New-Object System.Collections.Generic.List[object]
                for ($b = 0; $b -lt $nb; $b++) {
                    if ($tcnt[$c][$b] -gt 0) { [void]$arr.Add([math]::Round($tsum[$c][$b] / $tcnt[$c][$b], 1)) } else { [void]$arr.Add($null) }
                }
                $key = switch ($c) { 'cpu_util_pct' { 'cpu' } 'gpu_util_pct' { 'gpu' } 'gpu_temp_c' { 'temp' } 'gpu_power_w' { 'power' } }
                $trend[$key] = $arr.ToArray()
            }
        }
    }
}

# ── B3：瓶颈诊断（结论 + 依据指标）──
# 只下「数据能支撑」的判断：
#   · 没有帧率目标 → 不判「帧率不达标」；
#   · 显存总量拿不到 → 不判「显存占用 ≥ 90%」；
#   · CPU 温度/功耗拿不到 → 不判 CPU 降频。
# 依据里的数字全部来自本次采集，缺的就不写，绝不补 0。
$diag = $null
if ($avgFT -gt 0 -and $frameTimes.Count -ge 30) {
    $ftMed0 = [double](Get-Percentile $frameTimes 0.5)
    $cpuShare = if ($null -ne $cpuBusyMs) { [math]::Round(100.0 * [double]$cpuBusyMs / $avgFT, 1) } else { $null }
    # GPU Busy（真·忙时占比）与 GPU 平均利用率是两回事，判定只用前者，两者各占一行依据
    $gpuBusy = $gpuBusyPct
    $gpuUtilAvg = if ($gpuUtil) { [math]::Round($gpuUtil.Avg, 1) } else { $null }
    $cpuUtilAvg = if ($cpuUtil) { [math]::Round($cpuUtil.Avg, 1) } else { $null }
    $coreMaxPct = if ($cpuMaxCore) { [math]::Round($cpuMaxCore.Max, 1) } else { $null }
    $procCpuAvg = if ($procCpu) { [math]::Round($procCpu.Avg, 1) } else { $null }

    # 判定：CPU 交付占满帧时间、但 GPU Busy 也很高时，只能说「CPU 侧轻度倾向」，不能拍板
    $primary = 'unknown'
    if ($null -ne $gpuBusy -and $gpuBusy -ge 95 -and ($null -eq $cpuShare -or $cpuShare -le 80)) {
        $primary = 'gpu'
    } elseif ($null -ne $cpuShare -and $cpuShare -ge 95) {
        $primary = if ($null -ne $gpuBusy -and $gpuBusy -ge 70) { 'cpu_light' } else { 'cpu' }
    } elseif ($null -ne $cpuShare -and $cpuShare -ge 80) {
        $primary = 'cpu_light'
    } elseif ($null -ne $gpuBusy -and $null -ne $cpuShare) {
        $primary = 'balanced'
    }

    # 依据：最多 4 条，只放结论真正用的数（GPU 渲染/等待时间在 05 的板块行里已有，不重复）
    $ev = New-Object System.Collections.ArrayList
    if ($null -ne $gpuBusy) { [void]$ev.Add([ordered]@{ metric = 'bottleneck.gpuBusy'; name = 'GPU Busy（忙时占比）'; value = (Fmt $gpuBusy '0.0') + ' %' }) }
    if ($null -ne $gpuUtilAvg) { [void]$ev.Add([ordered]@{ metric = 'gpu.util'; name = 'GPU 平均利用率'; value = (Fmt $gpuUtilAvg '0') + ' %' }) }
    if ($null -ne $cpuShare) { [void]$ev.Add([ordered]@{ metric = 'bottleneck.cpuFrameTime'; name = 'CPU 帧处理时间'; value = (Fmt $cpuBusyMs '0.00') + ' ms（占帧时间 ' + (Fmt $cpuShare '0.0') + ' %）' }) }
    [void]$ev.Add([ordered]@{ metric = 'perf.avgFt'; name = '平均帧时间'; value = (Fmt $avgFT '0.00') + ' ms（≈ ' + (Fmt $avgFPS '0.0') + ' FPS）' })

    # 其它命中项：不影响主结论，但要说出来
    $find = New-Object System.Collections.ArrayList
    if ($sysAvail -and $null -ne $sysAvail.Min -and [double]$sysAvail.Min -lt 1024) {
        [void]$find.Add([ordered]@{ id = 'mem'; level = 'warn'; metric = 'mem.availableRam'; name = '系统剩余内存'; value = (Fmt $sysAvail.Min '0') + ' MB' })
    }
    if ($vramTotalMb -and $gpuMemUsed -and $gpuMemUsed.Max -gt 0) {
        $vramPct = [math]::Round(100.0 * [double]$gpuMemUsed.Max / [double]$vramTotalMb, 1)
        if ($vramPct -ge 90) {
            [void]$find.Add([ordered]@{ id = 'vram'; level = 'warn'; metric = 'mem.systemVram'; name = '显存占用'; value = (Fmt $gpuMemUsed.Max '0') + ' / ' + (Fmt $vramTotalMb '0') + ' MB（' + (Fmt $vramPct '0.0') + ' %）' })
        }
    }
    if ($stutterSegments.Count -gt 0 -and $ftP99 -gt (2.0 * $ftMed0) -and $null -ne $ftStdPct -and [double]$ftStdPct -gt 20.0) {
        [void]$find.Add([ordered]@{ id = 'stability'; level = 'warn'; metric = 'perf.stutterCount'; name = '稳定性'; value = '卡顿 ' + $stutterSegments.Count + ' 段 · P99 ' + (Fmt $ftP99 '0.0') + ' ms · 抖动 ' + (Fmt $ftStdPct '0.0') + ' %' })
    }
    $thrHit = @()
    foreach ($tk in @('sw_power_cap', 'sw_thermal', 'hw_thermal')) {
        if (-not $throttle.Contains($tk)) { continue }
        $nm = if ($thrNames.Contains($tk)) { $thrNames[$tk] } else { $tk }
        $thrHit += ($nm + ' ' + (Fmt $throttle[$tk] '0.0') + '%')
    }
    if ($thrHit.Count -gt 0) {
        [void]$find.Add([ordered]@{ id = 'thermal'; level = 'warn'; metric = 'gpu.throttle'; name = '降频'; value = ($thrHit -join ' · ') })
    }
    $diagLevel = if ($find.Count -gt 0) { 'warn' } else { 'good' }
    # 说明：CPU 侧结论要解释「整机不忙但单核吃紧」这件事，否则用户看不懂 18.5% 怎么就成了瓶颈
    $noteKey = ''
    $noteParams = @{}
    if ($primary -eq 'cpu' -or $primary -eq 'cpu_light') {
        $noteKey = 'cpu_core'
        $noteParams = @{ core = (Fmt $coreMaxPct '0.0'); total = (Fmt $cpuUtilAvg '0.0'); proc = (Fmt $procCpuAvg '0.0'); share = (Fmt $cpuShare '0.0') }
    } elseif ($primary -eq 'gpu') {
        $noteKey = 'gpu_busy'
        $noteParams = @{ busy = (Fmt $gpuBusy '0.0'); share = (Fmt $cpuShare '0.0') }
    }
    $diag = [ordered]@{
        primary       = $primary
        level         = $diagLevel
        cpu_share_pct = $cpuShare
        gpu_busy_pct  = $gpuBusy
        gpu_util_pct  = $gpuUtilAvg
        gpu_load_pct  = $gpuBusy          # 旧字段保留：语义=GPU Busy
        note_key      = $noteKey
        note_params   = $noteParams
        evidence      = @($ev.ToArray())
        findings      = @($find.ToArray())
    }
}

# 帧率落回 1% Low 附近的频率：保留计算（旧报告字段 low_hits_pct 仍在），但不再参与任何判定
$lowNearPct = 10
$lowBins = 0; $lowHits = 0
if ($chartAvg.Count -gt 0 -and $fps1Low -gt 0) {
    $lowBins = $chartAvg.Count
    $lowThr = $fps1Low * (1.0 + $lowNearPct / 100.0)
    foreach ($ft in $chartAvg) {
        if ($ft -gt 0 -and (1000.0 / $ft) -le $lowThr) { $lowHits++ }
    }
}
$lowHitsPct  = if ($lowBins -gt 0) { [math]::Round(100.0 * $lowHits / $lowBins, 1) } else { 0 }
$lowRatioPct = if ($avgFPS -gt 0) { [math]::Round(100.0 * $fps1Low / $avgFPS, 1) } else { 0 }

# ---------------------------------------------------------------- graphics features

$features = New-Object System.Collections.ArrayList
$fgOn = $false
$apiName = 'Unknown'
$presentMode = ''
if ($collectFeatures) {
$apiName = 'Unknown'
$presentMode = ''
for ($ln2 = 1; $ln2 -lt $csvLines.Count; $ln2++) {
    $f2 = $csvLines[$ln2] -split ','
    if ($f2.Count -ne $colCount) { continue }
    if ($iPid -ge 0 -and $f2[$iPid] -ne "$GamePid") { continue }
    if ($iRt -ge 0) { $apiName = $f2[$iRt] }
    if ($iPm -ge 0) { $presentMode = $f2[$iPm] }
    break
}
$features = New-Object System.Collections.ArrayList
if ($apiName -eq 'DXGI') { $apiText = 'DirectX (DXGI)' } elseif ($apiName -eq 'Vulkan') { $apiText = 'Vulkan' } else { $apiText = $apiName }
[void]$features.Add(@('feature.api', $apiText, 'PresentMon PresentRuntime'))
if ($presentMode) { [void]$features.Add(@('feature.presentMode', $presentMode, 'PresentMon PresentMode')) }

$modState = 'unknown'
$modList = @()
try {
    if (-not ('PerfMod' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class PerfMod {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint a, bool i, int pid);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("psapi.dll", SetLastError=true)] public static extern bool EnumProcessModulesEx(IntPtr h, IntPtr[] m, int cb, out int need, uint f);
    [DllImport("psapi.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern int GetModuleBaseNameW(IntPtr h, IntPtr m, StringBuilder sb, int n);
    public static List<string> Get(int pid, out int err) {
        var res = new List<string>(); err = 0;
        IntPtr p = OpenProcess(0x1000 | 0x0010, false, pid);
        if (p == IntPtr.Zero) { err = Marshal.GetLastWin32Error(); return res; }
        try {
            var buf = new IntPtr[4096]; int need;
            if (!EnumProcessModulesEx(p, buf, buf.Length * IntPtr.Size, out need, 3)) { err = Marshal.GetLastWin32Error(); return res; }
            int n = need / IntPtr.Size; var sb = new StringBuilder(512);
            for (int i = 0; i < n && i < buf.Length; i++) { sb.Clear(); if (GetModuleBaseNameW(p, buf[i], sb, 512) > 0) res.Add(sb.ToString()); }
        } finally { CloseHandle(p); }
        return res;
    }
}
'@
    }
    $modErr = 0
    $mods = [PerfMod]::Get($GamePid, [ref]$modErr)
    if ($modErr -ne 0 -or $mods.Count -eq 0) { $modState = 'blocked' } else { $modState = 'ok'; $modList = @($mods) }
} catch { $modState = 'error' }

# ── 超分：四种模式互斥（DLSS / FSR / XeSS / TSR）──
#   旧做法只看「进程里有没有加载某个 dll」，而游戏会把多个超分库一起加载 →
#   三项全报「已加载」，甚至没开光追也报光线重建。现在先定「选了哪一种模式」，
#   再判断那一种是否真的就位；没选中的模式直接不报。
$mDlss = $false; $mDlssg = $false; $mDlssd = $false; $mFsr = $false; $mXess = $false
if ($modState -eq 'ok') {
    $jmods = ' ' + ($modList -join ' ')
    $mDlss  = [bool]($jmods -match '(?i)nvngx_dlss\.dll')
    $mDlssg = [bool]($jmods -match '(?i)nvngx_dlssg\.dll')
    $mDlssd = [bool]($jmods -match '(?i)nvngx_dlssd\.dll')
    $mFsr   = [bool]($jmods -match '(?i)fidelityfx|ffx_')
    $mXess  = [bool]($jmods -match '(?i)libxess')
}

$fgOn = $false
# 游戏配置：video_quality_upscaler_2 是超分模式选择器（界面顺序 ×1000）
$pfKey = 'HKCU:\SOFTWARE\Hypergryph\Endfield'
$upCode = $null; $upMode = ''; $upModeName = ''; $upSharp = $null; $upUnknown = $false
if (Test-Path $pfKey) {
    try {
        $rk = Get-Item $pfKey
        $valNames = @($rk.GetValueNames())
        $getVal = {
            param($prefix)
            $n = $valNames | Where-Object { $_ -like ($prefix + '_h*') } | Select-Object -First 1
            if ($n) { return $rk.GetValue($n) } else { return $null }
        }
        $up = & $getVal 'video_quality_upscaler_2'
        $fgen = & $getVal 'video_quality_framegen_1'
        if ($fgen -eq 2000) { $fgOn = $true }
        $dg = & $getVal 'video_quality_dlssg_mode_1'
        $dm = & $getVal 'video_quality_dlss_mode_1'
        $rx = & $getVal 'video_quality_reflex_1'
        if ($null -ne $fgen) {
            $fgText = [string]$fgen
            if ($fgen -eq 1000) { $fgText = 'value.off' } elseif ($fgen -eq 2000) { $fgText = 'value.on' }
            [void]$features.Add(@('feature.framegenMode', $fgText, 'video_quality_framegen_1'))
        }
        if ($null -ne $dm) { [void]$features.Add(@('feature.dlssMode', [string]$dm, 'video_quality_dlss_mode_1 原始值')) }
        if ($null -ne $dg) { [void]$features.Add(@('feature.framegenModeLevel', [string]$dg, 'video_quality_dlssg_mode_1 原始值')) }
        if ($null -ne $up) { [void]$features.Add(@('feature.upscalerLevel', [string]$up, 'video_quality_upscaler_2 原始值')) }
        if ($null -ne $rx) { [void]$features.Add(@('feature.reflex', [string]$rx, 'video_quality_reflex_1 原始值')) }

        # 编码 → 模式：游戏按「界面顺序 ×1000」写（DLSS / FSR / XeSS / TSR）。
        # 这是根据实测配置推断的，不是官方文档 —— 原始编码一律带进报告，用户能自己核对。
        if ($null -ne $up) {
            $upCode = [string]$up
            $n = 0
            if ([int]::TryParse($upCode, [ref]$n)) {
                switch ($n) {
                    1000 { $upMode = 'dlss'; $upModeName = 'DLSS' }
                    2000 { $upMode = 'fsr';  $upModeName = 'FSR' }
                    3000 { $upMode = 'xess'; $upModeName = 'XeSS' }
                    4000 { $upMode = 'tsr';  $upModeName = 'TSR' }
                    default { $upUnknown = $true }
                }
            } else { $upUnknown = $true }
        }
    } catch { }
}

$modeLoaded = @{ dlss = $mDlss; fsr = $mFsr; xess = $mXess; tsr = $true }   # TSR 是引擎内置，选中即在
if ($upMode) {
    [void]$features.Add(@('feature.upscalerActive', $upModeName, '按 video_quality_upscaler_2 = ' + $upCode + ' 判定当前模式'))
    $isOn = [bool]$modeLoaded[$upMode]
    # 选中模式的「超分」是否就位：DLSS 看 nvngx_dlss.dll，FSR / XeSS 看各自库
    [void]$features.Add(@(('feature.upscale.' + $upMode), $(if ($isOn) { 'value.loaded' } else { 'value.notLoaded' }),
        ('模式 = ' + $upModeName + '；库' + $(if ($isOn) { '已加载' } else { '未加载' }))))
}
if (-not $upMode) { $upUnknown = ($null -ne $upCode) }

# DLSS 专属项只在「当前模式 = DLSS」时才有意义
if ($upMode -eq 'dlss') {
    [void]$features.Add(@('feature.dlss.framegen', $(if ($mDlssg) { 'value.loaded' } else { 'value.notLoaded' }), 'nvngx_dlssg.dll'))
    # 光线重建：只有「DLSS 模式 + 游戏内开启光线重建 + 光追」才会加载 nvngx_dlssd.dll。
    # 本版读不到光追开关，dll 存在也不能当成「已启用」——按「未检测到启用」报，不猜。
    [void]$features.Add(@('feature.dlss.rayReconstruction', 'value.notEnabled', '需要游戏内开启光线重建；本版无光追开关证据'))
}
if ($modState -ne 'ok' -and -not $upMode) {
    $why = if ($modState -eq 'blocked') { '进程受反作弊保护，外部无法枚举模块' } else { '读取模块失败' }
    [void]$features.Add(@('feature.upscalers', 'value.unavailable', $why))
}

}
# ---------------------------------------------------------------- verdicts
$verdicts = New-Object System.Collections.ArrayList
if ($avgFPS -ge 120) { [void]$verdicts.Add(@('good', 'verdict.fps.excellent', @{ fps = [math]::Round($avgFPS,1) })) }
elseif ($avgFPS -ge 60) { [void]$verdicts.Add(@('good', 'verdict.fps.base60', @{ fps = [math]::Round($avgFPS,1) })) }
elseif ($avgFPS -ge 45) { [void]$verdicts.Add(@('warn', 'verdict.fps.low', @{ fps = [math]::Round($avgFPS,1) })) }
else { [void]$verdicts.Add(@('bad', 'verdict.fps.poor', @{ fps = [math]::Round($avgFPS,1) })) }

# 2.0.5：删掉「仅 x% 的时间落回 1% Low 附近」这一族判定 —— 「落回 1% Low 附近的秒数占比」
# 既不是行业口径，也和用户看到的曲线对不上（曲线有尖峰、卡顿却是 0）。改成两句可以逐字核对的事实：
#   ① 1% Low 占平均帧率的多少（口径：最差 1% 帧的平均帧时间换算）
#   ② 最慢一帧多少毫秒、超过阈值的卡顿几段 —— 直接说明「为什么尖峰不等于卡顿」
if ($avgFPS -gt 0 -and $null -ne $fps1Low) {
    $lowPctTxt = [math]::Round(100.0 * $fps1Low / $avgFPS, 1)
    $lowLevel = if ($lowPctTxt -ge 70) { 'good' } elseif ($lowPctTxt -ge 50) { 'warn' } else { 'bad' }
    [void]$verdicts.Add(@($lowLevel, 'verdict.low.ratio', @{ pct = $lowPctTxt; low = [math]::Round($fps1Low,1); avg = [math]::Round($avgFPS,1) }))
}
if ($null -ne $ftMax) {
    $stCnt = if ($stutterSegments) { $stutterSegments.Count } else { 0 }
    $ftLevel = if ($ftMax -gt 100) { 'warn' } elseif ($stCnt -gt 0) { 'warn' } else { 'good' }
    [void]$verdicts.Add(@($ftLevel, 'verdict.ft.maxframe', @{ ms = [math]::Round($ftMax,1); n = $stCnt; thr = [int]$StutterMs }))
}

if ($ftP95 -gt 50) { [void]$verdicts.Add(@('warn', 'verdict.ft.spikes', @{ ms = [math]::Round($ftP95,1) })) }

if ($latStat) {
    if ($latStat.Avg -gt 33.3) { [void]$verdicts.Add(@('bad', 'verdict.lat.high', @{ ms = [math]::Round($latStat.Avg,1) })) }
    elseif ($latStat.Avg -gt 16.7) { [void]$verdicts.Add(@('warn', 'verdict.lat.slightlyHigh', @{ ms = [math]::Round($latStat.Avg,1) })) }
    else { [void]$verdicts.Add(@('good', 'verdict.lat.normal', @{ ms = [math]::Round($latStat.Avg,1) })) }
    if ($null -ne $pcLatAvg) {
        $pcParams = @{ ms = [math]::Round($pcLatAvg,1); ft = [math]::Round($avgFT,1); lat = [math]::Round($latStat.Avg,1) }
        if ($pcLatAvg -gt 66.7) { [void]$verdicts.Add(@('bad', 'verdict.pc.high', $pcParams)) }
        elseif ($pcLatAvg -gt 33.3) { [void]$verdicts.Add(@('warn', 'verdict.pc.slightlyHigh', $pcParams)) }
        else { [void]$verdicts.Add(@('good', 'verdict.pc.normal', $pcParams)) }
    }
}

if ($gpuTemp) {
    if ($gpuTemp.Max -ge 87) { [void]$verdicts.Add(@('bad', 'verdict.gpu.hot', @{ c = [math]::Round($gpuTemp.Max,0) })) }
    elseif ($gpuTemp.Max -ge 80) { [void]$verdicts.Add(@('warn', 'verdict.gpu.warm', @{ c = [math]::Round($gpuTemp.Max,0) })) }
    else { [void]$verdicts.Add(@('good', 'verdict.gpu.ok', @{ c = [math]::Round($gpuTemp.Max,0) })) }
}

if ($gpuUtil) {
    if ($gpuUtil.Avg -ge 95) { [void]$verdicts.Add(@('warn', 'verdict.gpu.saturated', @{ pct = [math]::Round($gpuUtil.Avg,0) })) }
    elseif ($gpuUtil.Avg -lt 70 -and $avgFPS -lt 60) { [void]$verdicts.Add(@('warn', 'verdict.gpu.cpuBound', @{ pct = [math]::Round($gpuUtil.Avg,0); fps = [math]::Round($avgFPS,1) })) }
    else { [void]$verdicts.Add(@('good', 'verdict.gpu.reasonable', @{ pct = [math]::Round($gpuUtil.Avg,0) })) }
}

if ($fgOn) { [void]$verdicts.Add(@('good', 'verdict.framegen.on')) }
if ($stalled) { [void]$verdicts.Add(@('bad', 'verdict.stalled')) }
elseif ($wallSec -gt 0 -and $durSec -lt ($wallSec * 0.6)) {
    [void]$verdicts.Add(@('warn', 'verdict.partial', @{ dur = [math]::Round($durSec,1); wall = $wallSec }))
}
# ---------------------------------------------------------------- 数据可信度与条件指纹（2.1.13）
# 判定逻辑在 quality-rules.ps1（纯函数、无副作用，探针可直接验证）；这里只负责喂事实，不在这里做判断。
$gpuSampleTotal = @($sensors).Count
$gpuSampleOk = 0
foreach ($srow in @($sensors)) {
    $gv = [string]$srow.gpu_util_pct
    if ($gv -and $gv -ne 'NA') { $gpuSampleOk++ }
}
if (Get-Command Get-CaptureQuality -ErrorAction SilentlyContinue) {
    $quality = Get-CaptureQuality -Frames $frameTimes.Count -EffectiveSeconds $durSec -WallSeconds $wallSec `
        -Stalled $stalled -ForegroundPct $fgPct -GpuRequested $collectGpuUsage `
        -SensorSamples $gpuSampleTotal -GpuSamplesOk $gpuSampleOk
} else {
    # 模块缺失时如实标 unknown：前端不显示横幅，也不许当成「检查通过」
    $quality = [ordered]@{ level = 'unknown'; checks = @() }
}

# 条件指纹：跨次对比的前提（F0-2）。取不到就留 null，不写「未知」冒充数值。
$driverVer = $null
try {
    if (Test-Path -LiteralPath $smi) {
        $dv = & $smi '--query-gpu=driver_version' '--format=csv,noheader' 2>$null | Select-Object -First 1
        if ($dv) { $driverVer = ([string]$dv).Trim() }
    }
} catch { $driverVer = $null }

$summary = [ordered]@{
    schema_version   = 3
    na_metrics       = @($naMetrics)
    # 本次数据是否足以支撑结论：level = ok / caution / blocked / unknown（模块缺失）
    # checks 里只列「确实触发的项」，没触发不等于逐项检查过（见 quality-rules.ps1 的说明）
    quality          = $quality
    stutter_threshold_ms = $StutterMs
    fps_01pct_low    = [math]::Round($fps01Low, 1)
    fps_min          = [math]::Round($minFPS, 1)
    frametime_p99_ms = [math]::Round($ftP99, 2)
    stutter          = [ordered]@{
        count = $stutterCount
        total_ms = [math]::Round($stutterTotalMs, 1)
        worst_ms = [math]::Round($stutterWorstMs, 1)
        severe = $severeCount
        top = @($stutterTop | ForEach-Object { [ordered]@{ start_frame = $_.start; frames = $_.frames; ms = $_.ms } })
        # 卡顿时刻上下文（2.1.16）：Top N 卡顿前后 ±window 秒的机器状态。
        # reason 说明「为什么没有」：noStutter / noSensors / noFrames / moduleMissing，不写空数组冒充「没卡顿」。
        context = $stutterCtx
    }
    bottleneck       = [ordered]@{
        gpu_busy_pct = $gpuBusyPct
        cpu_frame_ms = $cpuBusyMs
        gpu_render_ms = $gpuRenderMs
        gpu_wait_ms = $gpuWaitMs
        render_queue = $null
    }
    memory           = [ordered]@{
        proc_ram_max_mb = $(if ($procRam) { [math]::Round($procRam.Max, 0) } else { $null })
        sys_ram_avg_pct = $(if ($sysRam) { [math]::Round($sysRam.Avg, 1) } else { $null })
        sys_ram_max_pct = $(if ($sysRam) { [math]::Round($sysRam.Max, 1) } else { $null })
        sys_ram_min_avail_mb = $(if ($sysAvail) { [math]::Round($sysAvail.Min, 0) } else { $null })
        sys_commit_max_mb = $(if ($sysCommit) { [math]::Round($sysCommit.Max, 0) } else { $null })
        shared_vram_max_mb = $(if ($sharedVram) { [math]::Round($sharedVram.Max, 0) } else { $null })
        shared_vram_avg_mb = $(if ($sharedVram) { [math]::Round($sharedVram.Avg, 0) } else { $null })
        # 采不到时给出原因码，报告据此显示「暂不可用」而不是把这一行藏掉
        shared_vram_state = $(if (-not $collectShared) { 'skipped' } elseif ($null -eq $sharedVram) { 'noAdapterInstance' } else { 'ok' })
    }
    cpu_extra        = [ordered]@{
        proc_cpu_avg_pct = $(if ($procCpu) { [math]::Round($procCpu.Avg, 1) } else { $null })
        proc_cpu_max_pct = $(if ($procCpu) { [math]::Round($procCpu.Max, 1) } else { $null })
        # CPU 封装功耗（含核显与 uncore）：口径必须写清，报告里不许简写成「CPU 功耗」
        pkg_power_avg_w = $(if ($cpuPkg) { [math]::Round($cpuPkg.Avg, 1) } else { $null })
        pkg_power_max_w = $(if ($cpuPkg) { [math]::Round($cpuPkg.Max, 1) } else { $null })
        # 采不到时说清是哪一种：skipped = 用户关了开关；unavailable = 这台机器没有这个计数器
        pkg_power_state = $(if (-not $collectCpuPower) { 'skipped' } elseif ($null -eq $cpuPkg) { 'unavailable' } else { 'ok' })
    }
    # CPU 温度与降频：来源必须在报告里可见（规则文档 §5）。
    # temp_state / throttle_reason 让报告能区分「不支持」「读取失败」「未记录」三种情况。
    cpu_thermal      = [ordered]@{
        temp_avg_c      = $(if ($cpuTemp) { [math]::Round($cpuTemp.Avg, 1) } else { $null })
        temp_max_c      = $(if ($cpuTemp) { [math]::Round($cpuTemp.Max, 1) } else { $null })
        temp_min_c      = $(if ($cpuTemp) { [math]::Round($cpuTemp.Min, 1) } else { $null })
        temp_samples    = $(if ($cpuTemp) { $cpuTemp.N } else { 0 })
        temp_state      = $cpuTempState       # ok / skipped / unsupported / failed
        temp_reason     = $cpuTempReason      # vendorNotSupported / vendorNeedsAdmin / vendorReadFailed …
        temp_source     = $cpuTempSource      # vendor-wmi:lenovo-wmi
        throttle_state  = $throttleState      # ok / skipped / unavailable
        throttle_ok     = $throttleOk         # 日志查询是否成功（成功但 0 条 = 未记录到限速）
        throttle_count  = $throttleCount
        throttle_cores  = $throttleCores
        throttle_max_s  = $throttleMaxS
        throttle_reason = $throttleReason
        throttle_source = 'winevent:kpp-37'   # Microsoft-Windows-Kernel-Processor-Power / Event 37
    }
    environment      = [ordered]@{
        cpu_model = $cpuModelText
        ram_type = $ramTypeText
        gpu_model = $gpuModelText
        vram_type = $null
        # 帧数据源（2.1.10）：同一次采集单一来源，presentmon 或扩展 id；跨机器比较报告必须先对齐这里。
        fps_source = $FpsSource
        present_api = $apiName
        present_mode = $presentMode
        # 供电侧（07 测试环境）：台机没有电池时 battery_* 为 null，报告侧不显示该行，不当错误
        power_source        = $powerSource        # ac / battery / mixed / unknown
        ac_off_pct          = $acOffPct           # 采集期间不在交流电上的样本占比
        battery_present     = $(if ($batteryPct) { $true } else { $false })
        battery_min_pct     = $(if ($batteryPct) { [math]::Round($batteryPct.Min, 0) } else { $null })
        battery_max_pct     = $(if ($batteryPct) { [math]::Round($batteryPct.Max, 0) } else { $null })
        gpu_limit_min_w     = $(if ($gpuLimit) { [math]::Round($gpuLimit.Min, 1) } else { $null })
        gpu_limit_max_w     = $(if ($gpuLimit) { [math]::Round($gpuLimit.Max, 1) } else { $null })
        power_events        = $powerEvents        # 采集窗口内 Kernel-Power 105 的条数
        power_health        = $powerHealth        # ok / events / $null(查询失败)
        power_health_detail = $powerHealthDetail
        # 平台覆盖（v2.1.11）：跨机器对比前先看这里；不支持的组合在指标处如实 N/A
        cpu_vendor          = $(if ($platform) { [string]$platform.cpuVendor } else { $null })
        gpu_vendor          = $(if ($platform) { [string]$platform.gpuVendor } else { $null })
        system_vendor       = $(if ($platform) { [string]$platform.systemVendor } else { $null })
        system_model        = $(if ($platform) { [string]$platform.systemModel } else { $null })
        os_build            = $(if ($platform) { [int]$platform.osBuild } else { $null })
        # 条件指纹（2.1.13）：跨次/跨机器对比前先对齐这几项，任何一项不同都不能直接比「提升」。
        # 驱动版本取不到就是 null —— 报告按「无法确认」渲染，不写猜测值。
        driver_version      = $driverVer
        os_version          = $(if ($platform) { [string]$platform.osName } else { $null })
        bios_version        = $(if ($platform) { [string]$platform.bios } else { $null })
    }
    run              = $runName
    process          = $exeBase
    resolution       = $(if ($collectRes -and $resW -gt 0) { "" + $resW + "x" + $resH } else { $null })
    window_mode      = $(if ($collectRes) { $winMode } else { $null })
    monitor          = $(if ($collectRes -and $monW -gt 0) { "" + $monW + "x" + $monH } else { $null })
    captured_seconds = [math]::Round($durSec, 1)
    foreground_pct   = $fgPct
    wall_seconds     = $wallSec
    stalled          = $stalled
    api              = $apiName
    present_mode     = $presentMode
    frames           = $frameTimes.Count
    avg_fps          = [math]::Round($avgFPS, 1)
    fps_1pct_low     = [math]::Round($fps1Low, 1)
    fps_1pct_low_pct = $lowRatioPct          # 1% Low 占平均帧率的百分比（报告顶部直接显示）
    low_hits_pct     = $lowHitsPct           # 有多少采样区间回落到 1% Low 附近（判定帧率是否稳）
    max_fps          = [math]::Round($maxFPS, 1)
    avg_frametime_ms = [math]::Round($avgFT, 2)
    frametime_p95_ms = [math]::Round($ftP95, 2)
    display_latency_avg_ms = if ($latStat) { [math]::Round($latStat.Avg, 2) } else { $null }
    display_latency_p95_ms = if ($latP95) { [math]::Round($latP95, 2) } else { $null }
    click_to_photon_avg_ms = if ($inStat) { [math]::Round($inStat.Avg, 2) } else { $null }
    gpu_util_avg_pct = if ($gpuUtil) { [math]::Round($gpuUtil.Avg, 1) } else { $null }
    gpu_util_max_pct = if ($gpuUtil) { [math]::Round($gpuUtil.Max, 1) } else { $null }
    gpu_temp_avg_c   = if ($gpuTemp) { [math]::Round($gpuTemp.Avg, 1) } else { $null }
    gpu_temp_max_c   = if ($gpuTemp) { [math]::Round($gpuTemp.Max, 1) } else { $null }
    vram_avg_mb      = if ($procVram) { [math]::Round($procVram.Avg, 0) } else { $null }
    vram_max_mb      = if ($procVram) { [math]::Round($procVram.Max, 0) } else { $null }
    ram_avg_mb       = if ($procRam) { [math]::Round($procRam.Avg, 0) } else { $null }
    ram_max_mb       = if ($procRam) { [math]::Round($procRam.Max, 0) } else { $null }
    gpu_mem_total_avg_mb = if ($gpuMemUsed) { [math]::Round($gpuMemUsed.Avg, 0) } else { $null }
    vram_total_mb    = $vramTotalMb
    pc_latency_avg_ms  = if ($null -ne $pcLatAvg) { [math]::Round($pcLatAvg, 2) } else { $null }
    pc_latency_p95_ms  = if ($null -ne $pcLatP95) { [math]::Round($pcLatP95, 2) } else { $null }
    # ---- 批次 C：帧时间分布 / 呈现→上屏 / 1% Low 双口径 / 预热 ----
    frametime_p999_ms   = [math]::Round($ftP999, 2)
    frametime_max_ms    = if ($null -ne $ftMax) { [math]::Round($ftMax, 2) } else { $null }
    frametime_median_ms = [math]::Round($ftMedian, 2)
    frametime_stddev_ms = if ($null -ne $ftStd) { [math]::Round($ftStd, 2) } else { $null }
    frametime_jitter_pct = if ($null -ne $ftStdPct) { [math]::Round($ftStdPct, 1) } else { $null }
    long_frames      = [ordered]@{ over2x = $long2x; over4x = $long4x; over50 = $long50; over100 = $long100; pct_over2x = $longPct; base_ms = [math]::Round($ftMedian, 2) }
    displayed_fps    = if ($null -ne $displayedFps) { [math]::Round($displayedFps, 1) } else { $null }
    repeat_frames    = $repeatFrames
    repeat_pct       = $repeatPct
    sync_interval    = $syncMode
    present_flags    = $flagsMode
    allows_tearing_pct = $allowTearPct
    fps_1pct_low_time  = if ($null -ne $fps1LowTime) { [math]::Round($fps1LowTime, 1) } else { $null }
    fps_1pct_low_time_pct = $fps1LowTimeRatio
    time_bins        = $secBins
    warmup_seconds   = $WarmupSec
    warmup_dropped   = $warmupDropped
    # ---- 批次 C：GPU 时钟 / 功耗 / 风扇 / PCIe / 降频原因 / CPU ----
    gpu_clock_avg_mhz     = if ($gpuClock) { [math]::Round($gpuClock.Avg, 0) } else { $null }
    gpu_clock_max_mhz     = if ($gpuClock) { [math]::Round($gpuClock.Max, 0) } else { $null }
    gpu_clock_hw_max_mhz  = if ($gpuClockMax) { [math]::Round($gpuClockMax.Max, 0) } else { $null }
    gpu_mem_clock_avg_mhz = if ($gpuMemClock) { [math]::Round($gpuMemClock.Avg, 0) } else { $null }
    gpu_power_avg_w       = if ($gpuPower) { [math]::Round($gpuPower.Avg, 1) } else { $null }
    gpu_power_max_w       = if ($gpuPower) { [math]::Round($gpuPower.Max, 1) } else { $null }
    gpu_fan_avg_pct       = if ($gpuFan) { [math]::Round($gpuFan.Avg, 0) } else { $null }
    pcie                  = $pcieText
    throttle              = $throttle
    cpu_util_avg_pct      = if ($cpuUtil) { [math]::Round($cpuUtil.Avg, 1) } else { $null }
    cpu_util_max_pct      = if ($cpuUtil) { [math]::Round($cpuUtil.Max, 1) } else { $null }
    cpu_max_core_avg_pct  = if ($cpuMaxCore) { [math]::Round($cpuMaxCore.Avg, 1) } else { $null }
    cpu_max_core_peak_pct = if ($cpuMaxCore) { [math]::Round($cpuMaxCore.Max, 1) } else { $null }
    chart            = if ($chartMs -and $chartMs.Count -gt 0) { [ordered]@{ per_bin = $chartPerBin; limit = $chartLimit; over = $chartOver; ms = @($chartMs); avg = @($chartAvg) } } else { $null }
    trend            = $trend
    diagnosis        = $diag
    features         = @($features)
    verdicts         = @($verdicts)
    # 每个可选开关到底采没采：报告据此把「用户关闭」与「不支持 / 没采到」分开，
    # 关闭的项显示「未采集」，绝不写 0、也不沿用上一次的值
    collected        = [ordered]@{
        latency   = $collectLatency
        proccpu   = $collectProcCpu
        cpupower  = $collectCpuPower
        gpuusage  = $collectGpuUsage
        gputemp   = $collectGpuTemp
        vram      = $collectVram
        ram       = $collectRam
        sysmem    = $collectSysMem
        sharedmem = $collectShared
        features  = $collectFeatures
        res       = $collectRes
        chart     = $collectChart
        diagnosis = $true        # 由已采数据推算，恒有
    }
}
# 深度 6：quality.checks 里的对象在 5 层，深度 3 会被压成字符串（历史遗留的隐患，一并修掉）
$summary | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonOut -Encoding UTF8

# ---------------------------------------------------------------- console output
Write-Host ''
Write-Host '================ RESULT ================' -ForegroundColor Cyan
Write-Host ("  captured        : " + $summary.captured_seconds + " s / " + $summary.frames + " frames")
Write-Host ("  avg FPS         : " + $summary.avg_fps)
Write-Host ("  1% low FPS      : " + $summary.fps_1pct_low + "  (占平均 " + $summary.fps_1pct_low_pct + "%, 落回 1% Low 附近 " + $summary.low_hits_pct + "% 的时间)")
Write-Host ("  avg frame time  : " + $summary.avg_frametime_ms + " ms  (p95 " + $summary.frametime_p95_ms + " ms, p99.9 " + $summary.frametime_p999_ms + " ms)")
Write-Host ("  jitter          : " + $(if ($null -ne $summary.frametime_stddev_ms) { "" + $summary.frametime_stddev_ms + " ms (" + $summary.frametime_jitter_pct + "%)" } else { "NA" }) + "   long frames >2x median: " + $summary.long_frames.over2x + " 帧 (" + $summary.long_frames.pct_over2x + "%)")
Write-Host ("  displayed FPS   : " + $(if ($null -ne $summary.displayed_fps) { "" + $summary.displayed_fps + " (上屏节奏; 重复帧 " + $summary.repeat_frames + " 帧 = " + $summary.repeat_pct + "%)" } else { "NA" }))
Write-Host ("  1% low (by sec) : " + $(if ($null -ne $summary.fps_1pct_low_time) { "" + $summary.fps_1pct_low_time + " FPS (占平均 " + $summary.fps_1pct_low_time_pct + "%, " + $summary.time_bins + " 个整秒桶)" } else { "NA" }))
Write-Host ("  sync / flags    : SyncInterval=" + $(if ($null -ne $summary.sync_interval) { $summary.sync_interval } else { "NA" }) + "  PresentFlags=" + $(if ($null -ne $summary.present_flags) { $summary.present_flags } else { "NA" }))
Write-Host ("  GPU clock/power : " + $(if ($null -ne $summary.gpu_clock_avg_mhz) { "" + $summary.gpu_clock_avg_mhz + " MHz avg / " + $summary.gpu_clock_max_mhz + " max (硬件上限 " + $summary.gpu_clock_hw_max_mhz + ")" } else { "NA" }) + $(if ($null -ne $summary.gpu_power_avg_w) { "  " + $summary.gpu_power_avg_w + " W avg / " + $summary.gpu_power_max_w + " max" } else { "" }))
if ($summary.throttle.Count -gt 0) {
    $thrText = @(); foreach ($k in $summary.throttle.Keys) { $thrText += ($k + ' ' + $summary.throttle[$k] + '%') }
    Write-Host ("  throttle        : " + ($thrText -join ', '))
} else { Write-Host '  throttle        : none' }
Write-Host ("  CPU             : " + $(if ($null -ne $summary.cpu_util_avg_pct) { "" + $summary.cpu_util_avg_pct + " % avg, 最高单核 " + $summary.cpu_max_core_avg_pct + " % (峰值 " + $summary.cpu_max_core_peak_pct + " %)" } else { "NA" }))
Write-Host ("  CPU package     : " + $(if ($null -ne $summary.cpu_extra.pkg_power_avg_w) { "" + $summary.cpu_extra.pkg_power_avg_w + " W avg / " + $summary.cpu_extra.pkg_power_max_w + " W max (iGPU + uncore included)" } else { "NA" }))
Write-Host ("  CPU temp        : " + $(if ($null -ne $summary.cpu_thermal.temp_max_c) { "" + $summary.cpu_thermal.temp_avg_c + " C avg / " + $summary.cpu_thermal.temp_max_c + " C max (" + $summary.cpu_thermal.temp_source + ")" } else { "NA (" + $summary.cpu_thermal.temp_reason + ")" }))
if (Get-Command Format-CpuThrottleSummary -ErrorAction SilentlyContinue) {
    Write-Host ("  CPU throttle    : " + (Format-CpuThrottleSummary $cpuThrottle))
} else {
    Write-Host "  CPU throttle    : NA (module missing)"
}
if ($summary.warmup_dropped -gt 0) { Write-Host ("  warmup          : 已丢弃开头 " + $summary.warmup_seconds + " s（" + $summary.warmup_dropped + " 帧）") }
Write-Host ("  display latency : " + $(if ($null -ne $summary.display_latency_avg_ms) { "" + $summary.display_latency_avg_ms + " ms (p95 " + $summary.display_latency_p95_ms + " ms)" } else { "NA" }))
Write-Host ("  GPU usage       : " + $(if ($null -ne $summary.gpu_util_avg_pct) { "" + $summary.gpu_util_avg_pct + " % (max " + $summary.gpu_util_max_pct + " %)" } else { "NA" }))
Write-Host ("  GPU temp        : " + $(if ($null -ne $summary.gpu_temp_avg_c) { "" + $summary.gpu_temp_avg_c + " C (max " + $summary.gpu_temp_max_c + " C)" } else { "NA" }))
Write-Host ("  VRAM (this app) : " + $(if ($null -ne $summary.vram_avg_mb) { "" + $summary.vram_avg_mb + " MB (max " + $summary.vram_max_mb + " MB)" } else { "NA" }))
Write-Host ("  Shared VRAM     : " + $(if ($null -ne $summary.memory.shared_vram_max_mb) { "" + $summary.memory.shared_vram_avg_mb + " MB (max " + $summary.memory.shared_vram_max_mb + " MB) · target game's adapter" } else { "NA" }))
$pwSrcTxt = switch ([string]$summary.environment.power_source) {
    'ac'      { '交流电' }
    'battery' { '电池' }
    'mixed'   { '交流电与电池混用（采集中发生切换）' }
    default   { '无法确认' }
}
if ($null -ne $summary.environment.ac_off_pct -and $summary.environment.ac_off_pct -gt 0 -and $summary.environment.ac_off_pct -lt 100) {
    $pwSrcTxt += '（电池时间占比 ' + (Fmt $summary.environment.ac_off_pct '0.0') + ' %）'
}
Write-Host ("  power           : " + $pwSrcTxt + $(if ($null -ne $summary.environment.gpu_limit_max_w) { " · GPU limit " + (Fmt $summary.environment.gpu_limit_max_w '0.0') + " W" } else { '' }) + $(if ($null -ne $summary.environment.power_events) { " · interruptions " + $summary.environment.power_events } else { '' }))
Write-Host ("  RAM  (this app) : " + $(if ($null -ne $summary.ram_avg_mb) { "" + $summary.ram_avg_mb + " MB (max " + $summary.ram_max_mb + " MB)" } else { "NA" }))
Write-Host ("  PC latency est. : " + $(if ($null -ne $summary.pc_latency_avg_ms) { "" + $summary.pc_latency_avg_ms + " ms (mean frametime + display latency; p95 " + $summary.pc_latency_p95_ms + " ms)" } else { "NA" }))
Write-Host ("  game foreground : " + $(if ($null -ne $summary.foreground_pct) { "" + $summary.foreground_pct + " % of the capture" } else { "NA" }))
Write-Host ''
Write-Host '---- graphics ----'
foreach ($x in $features) { Write-Host ("  " + $x[0] + " : " + $x[1] + "   (" + $x[2] + ")") }
Write-Host ''
Write-Host '---- verdicts ----'
foreach ($x in $verdicts) {
    $clr = 'Gray'; if ($x[0] -eq 'good') { $clr = 'Green' } elseif ($x[0] -eq 'warn') { $clr = 'Yellow' } elseif ($x[0] -eq 'bad') { $clr = 'Red' }
    Write-Host ("  [" + $x[0].ToUpper() + "] " + $x[1]) -ForegroundColor $clr
}
Write-Host '========================================' -ForegroundColor Cyan

# ---------------------------------------------------------------- HTML report
# 报告主题跟随 GUI 设置：-Theme light | dark
if ($Theme -eq 'light') {
    $cPage = '#e9e8ef'; $cPanel = '#ffffff'; $cLine = '#e3e0ec'
    $cText = '#333649'; $cStrong = '#262330'; $cMuted = '#666278'; $cFaint = '#8b8a99'
    $cAccent = '#716493'; $cGood = '#2f8f46'; $cWarn = '#a86f14'; $cBad = '#cf3b32'
    $cCodeBg = '#f0ecf6'; $cCardSh = '0 2px 12px #25203114'
} else {
    $cPage = '#0d1117'; $cPanel = '#161b22'; $cLine = '#21262d'
    $cText = '#e6edf3'; $cStrong = '#f0f6fc'; $cMuted = '#8b949e'; $cFaint = '#6e7681'
    $cAccent = '#58a6ff'; $cGood = '#3fb950'; $cWarn = '#d29922'; $cBad = '#f85149'
    $cCodeBg = '#1f242c'; $cCardSh = 'none'
}

$verdictItems = ''
foreach ($x in $verdicts) {
    $cls = 'good'
    if ($x[0] -eq 'warn') { $cls = 'warn' } elseif ($x[0] -eq 'bad') { $cls = 'bad' }
    $verdictItems += '<div class="item ' + $cls + '"><span>' + $x[1] + '</span></div>' + "`n"
}
if ($stalled) { $verdictItems = '<div class="item bad"><span>采集被中断：游戏停止出帧，数据不完整</span></div>' + "`n" + $verdictItems }

$featureRows = ''
foreach ($x in $features) {
    $featureRows += '<tr><td class="fk">' + $x[0] + '</td><td class="fv">' + $x[1] + '</td><td class="fs">' + $x[2] + '</td></tr>' + "`n"
}

$chartSvg = ''
$chartYlab = ''
$chartCap = ''
# 卡顿位置标注（2.1.16）：按 at_pct 画竖虚线，让人一眼看到「卡在哪一段」
$markSvg = ''
if ($stutterCtx -and $stutterCtx.items) {
    foreach ($it in @($stutterCtx.items)) {
        $mx = [math]::Round([double]$it.at_pct * 10.0, 1)
        if ($mx -lt 0 -or $mx -gt 1000) { continue }
        $markSvg += '<line x1="' + $mx + '" y1="0" x2="' + $mx + '" y2="150" stroke="' + $cBad + '" stroke-width="1" stroke-dasharray="3 4" opacity="0.55" vector-effect="non-scaling-stroke"/>'
    }
}
if ($collectChart -and $chartMs -and $chartMs.Count -gt 2) {
    $limit = [double]$chartLimit
    $nBin = $chartMs.Count
    $pts = New-Object System.Collections.Generic.List[string]
    for ($b = 0; $b -lt $nBin; $b++) {
        $v = [double]$chartMs[$b]
        if ($v -gt $limit) { $v = $limit }
        $x = [math]::Round(1000.0 * $b / [math]::Max(1, $nBin - 1), 1)
        $y = [math]::Round(150.0 - ($v / $limit) * 150.0, 1)
        $pts.Add([string]$x + ',' + [string]$y)
    }
    $poly = $pts -join ' '

    $grid = ''
    for ($g = 0; $g -le 4; $g++) {
        $gy = [math]::Round($g * 37.5, 1)
        $grid += '<line x1="0" y1="' + $gy + '" x2="1000" y2="' + $gy + '" stroke="' + $cLine + '" stroke-width="1" vector-effect="non-scaling-stroke"/>'
    }
    $refLine = ''
    if ($limit -ge 16.7) {
        $ry = [math]::Round(150.0 - (16.7 / $limit) * 150.0, 1)
        $refLine = '<line x1="0" y1="' + $ry + '" x2="1000" y2="' + $ry + '" stroke="' + $cGood + '" stroke-width="1" stroke-dasharray="6 6" opacity="0.6" vector-effect="non-scaling-stroke"/>'
    }
    $chartSvg = '<svg viewBox="0 0 1000 150" preserveAspectRatio="none" role="img">' +
                '<defs><linearGradient id="ftfill" x1="0" y1="0" x2="0" y2="1">' +
                '<stop offset="0" stop-color="' + $cAccent + '" stop-opacity="0.38"/>' +
                '<stop offset="1" stop-color="' + $cAccent + '" stop-opacity="0"/>' +
                '</linearGradient></defs>' + $grid + $refLine +
                '<polygon points="' + $poly + ' 1000,150 0,150" fill="url(#ftfill)"/>' +
                '<polyline points="' + $poly + '" fill="none" stroke="' + $cAccent + '" stroke-width="1.4" stroke-linejoin="round" vector-effect="non-scaling-stroke"/>' +
                $markSvg +
                '</svg>'

    $lbl = New-Object System.Collections.Generic.List[string]
    for ($t = 4; $t -ge 0; $t--) {
        $val = $limit * $t / 4.0
        $txt = if ($t -eq 0) { '0' } else { [string]::Format([cultureinfo]::InvariantCulture, '{0:0.0}', $val) }
        $lbl.Add('<span style="top:' + [string](($t - 4) * -25) + '%">' + $txt + '</span>')
    }
    $chartYlab = $lbl -join ''

    $chartCap = '帧时间曲线 · 时间轴 0–' + (Fmt $durSec '0.0') + 's · 每 ' + $chartPerBin + ' 帧取最慢 · 纵轴 0–' + (Fmt $limit '0.0') + ' ms'
    if ($chartOver -gt 0) { $chartCap += ' · ' + $chartOver + ' 帧超出上限已截顶' }
    if ($limit -ge 16.7) { $chartCap += ' · 绿虚线 = 60 FPS 基准 16.7 ms' }
}

function Card([string]$k, [string]$v, [string]$u, [string]$sub = '') {
    $extra = if ($sub) { '<div class="s">' + $sub + '</div>' } else { '' }
    return '<div class="card"><div class="k">' + $k + '</div><div class="v">' + $v + '<span class="u">' + $u + '</span></div>' + $extra + '</div>' + "`n"
}

# 指标卡按采集开关裁剪
$cards = ''
$cards += Card '平均帧率' (Fmt $summary.avg_fps '0.0') 'FPS'
$cards += Card '1% Low' (Fmt $summary.fps_1pct_low '0.0') ('FPS<span class="p">' + $summary.fps_1pct_low_pct + '%</span>')
if ($collectLatency) {
    $cards += Card '上屏延迟' $(if ($null -ne $summary.display_latency_avg_ms) { (Fmt $summary.display_latency_avg_ms '0.0') } else { 'NA' }) 'ms' '生成好的帧 → 被看到'
    $cards += Card 'PC 延迟（估算）' $(if ($null -ne $summary.pc_latency_avg_ms) { (Fmt $summary.pc_latency_avg_ms '0.0') } else { 'NA' }) 'ms' '平均帧时间 + 上屏延迟'
}
if ($collectGpuTemp) {
    $cards += Card 'GPU 温度' $(if ($null -ne $summary.gpu_temp_max_c) { (Fmt $summary.gpu_temp_max_c '0') } else { 'NA' }) '°C'
}
if ($collectGpuUsage) {
    $cards += Card 'GPU 占用' $(if ($null -ne $summary.gpu_util_avg_pct) { (Fmt $summary.gpu_util_avg_pct '0') } else { 'NA' }) '%'
}
if ($collectVram) {
    $cards += Card '显存占用' $(if ($null -ne $summary.vram_avg_mb) { (Fmt $summary.vram_avg_mb '0') } else { 'NA' }) 'MB'
}
if ($collectRam) {
    $cards += Card '内存占用' $(if ($null -ne $summary.ram_avg_mb) { (Fmt $summary.ram_avg_mb '0') } else { 'NA' }) 'MB'
}
if ($collectRes -and $summary.resolution) {
    $cards += Card '分辨率' ($summary.resolution -replace 'x', '×') '' $(if ($summary.window_mode) { $summary.window_mode } else { '' })
}

# 章节按采集开关裁剪
$secChart = ''
if ($chartSvg) {
    $secChart = '<div class="chapt">帧时间</div>' + "`n" + '<div class="chartbox">' + "`n" +
                '<div class="chartwrap"><div class="chart">' + $chartSvg + '</div><div class="ylab">' + $chartYlab + '</div></div>' + "`n" +
                '<div class="cap">' + $chartCap + '</div>' + "`n" + '</div>' + "`n"
}
$secFeatures = ''
# 游戏内档位三项：直接给原始编码（和应用内报告同口径），不写「暂不可用」
$presetRows = ''
if ($null -ne $upCode) { $presetRows += '<tr><td>超分档位（游戏内）</td><td>编码 ' + $upCode + '（含义未确认）</td></tr>' + "`n" }
if ($null -ne $dm) { $presetRows += '<tr><td>DLSS 档位（游戏内）</td><td>编码 ' + [string]$dm + '（含义未确认）</td></tr>' + "`n" }
if ($null -ne $dg) { $presetRows += '<tr><td>帧生成档位（游戏内）</td><td>编码 ' + [string]$dg + '（含义未确认）</td></tr>' + "`n" }
if ($presetRows) { $featureRows = '' + $featureRows + $presetRows }
if ($featureRows) {
    $secFeatures = '<h2>07 测试环境 · 图显特性</h2>' + "`n" + '<table>' + "`n" + $featureRows + '</table>' + "`n"
}
# ── B3：趋势小图（负载 / 温度 / 功耗）──
# 序列由引擎按时间桶算好，桶里没样本的点是 $null：图上直接断线，不补值也不插值。
function SvgSeries($vals, [double]$max, [string]$color, [double]$w = 320, [double]$h = 96) {
    if (-not $vals -or $vals.Count -lt 2 -or $max -le 0) { return '' }
    $n = $vals.Count
    $d = New-Object System.Text.StringBuilder
    $pen = $false
    for ($i = 0; $i -lt $n; $i++) {
        $v = $vals[$i]
        if ($null -eq $v) { $pen = $false; continue }
        $x = [math]::Round($w * $i / ($n - 1), 1)
        $y = [math]::Round($h * (1.0 - ([math]::Min([double]$v, $max) / $max)), 1)
        if (-not $pen) { [void]$d.Append('M' + $x + ',' + $y); $pen = $true } else { [void]$d.Append('L' + $x + ',' + $y) }
    }
    if ($d.Length -eq 0) { return '' }
    return '<path d="' + $d.ToString() + '" fill="none" stroke="' + $color + '" stroke-width="1.3" stroke-linejoin="round"/>'
}
function MaxOfSeries($vals, [double]$dflt) {
    $mx = $null
    foreach ($v in $vals) {
        if ($null -eq $v) { continue }
        $dv = [double]$v
        if ($null -eq $mx -or $dv -gt $mx) { $mx = $dv }
    }
    if ($null -eq $mx -or $mx -le 0) { return $dflt }
    return [math]::Ceiling($mx * 1.1 / 10.0) * 10.0
}
function MiniChart([string]$title, [string]$body, [string]$note) {
    if (-not $body) { return '' }
    return '<div class="mini"><div class="minit">' + $title + '</div>' +
           '<svg viewBox="0 0 320 96" preserveAspectRatio="none">' + $body + '</svg>' +
           '<div class="cap">' + $note + '</div></div>'
}
$secTrend = ''
if ($trend) {
    $miniGrid = '<g stroke="' + $cLine + '" stroke-width="1" vector-effect="non-scaling-stroke">' +
                '<line x1="0" y1="0" x2="320" y2="0"/><line x1="0" y1="96" x2="320" y2="96"/></g>'
    # 纵轴按数据取（固定 0–100 会把 13% 的 CPU 压成一条贴底平线，看着像没画）
    $lMax = [math]::Max(10, [math]::Max((MaxOfSeries $trend.cpu 100), (MaxOfSeries $trend.gpu 100)))
    $miniLoad  = MiniChart 'CPU / GPU 负载' ($miniGrid + (SvgSeries $trend.cpu $lMax $cAccent) + (SvgSeries $trend.gpu $lMax $cGood)) ('0–' + (Fmt $lMax '0') + ' %　蓝 = CPU　绿 = GPU')
    $tMax = MaxOfSeries $trend.temp 100
    $pMax = MaxOfSeries $trend.power 200
    $miniTemp  = MiniChart 'GPU 温度' ($miniGrid + (SvgSeries $trend.temp $tMax $cWarn)) ('0–' + (Fmt $tMax '0') + ' °C')
    $miniPower = MiniChart 'GPU 功耗' ($miniGrid + (SvgSeries $trend.power $pMax $cBad)) ('0–' + (Fmt $pMax '0') + ' W')
    if ($miniLoad -or $miniTemp -or $miniPower) {
        $secTrend = '<div class="mins">' + $miniLoad + $miniTemp + $miniPower + '</div>' +
                    '<div class="cap">按时间等分 ' + $trend.bins + ' 段（段内取平均；传感器采样比帧粗，段数按样本量自适应，每段约 2 个样本）；某段没有样本就断开，不补值、不插值。</div>'
    }
}

# ── 卡顿时刻（2.1.16）：Top N 卡顿前后 ±N 秒的机器状态 ──
# 两路数据不同源，只能按采集进度比例对齐；容差写在正文里，不许当成毫秒级因果证据。
$secStutter = ''
if ($stutterCtx -and @($stutterCtx.items).Count -gt 0) {
    $tolTxt = if ($null -ne $stutterCtx.tolerance_seconds) { [string]$stutterCtx.tolerance_seconds } else { '—' }
    # 对齐方式必须如实写：time = 按传感器时间戳；proportional = 按采集进度比例（误差更大）
    $alignTxt = if ([string]$stutterCtx.alignment -eq 'time') {
        '按传感器时间戳对齐，误差 ≤ ' + $tolTxt + ' 秒（时间戳只到整秒）'
    } else {
        '两路数据不同源，按采集进度比例对齐，误差约 ' + $tolTxt + ' 秒'
    }
    $sRows = ''
    $si = 0
    foreach ($it in @($stutterCtx.items)) {
        $si++
        $parts = @()
        if ($null -ne $it.avg.gpu_util) { $parts += ('GPU 占用 ' + (Fmt $it.avg.gpu_util '0') + ' %') }
        if ($null -ne $it.avg.gpu_temp) {
            $gt = 'GPU ' + (Fmt $it.avg.gpu_temp '0') + ' °C'
            if ($null -ne $it.peak.gpu_temp -and ([double]$it.peak.gpu_temp -gt [double]$it.avg.gpu_temp)) {
                $gt += '（峰值 ' + (Fmt $it.peak.gpu_temp '0') + ' °C）'
            }
            $parts += $gt
        }
        if ($null -ne $it.avg.vram_mb) { $parts += ('显存 ' + (Fmt $it.avg.vram_mb '0') + ' MB') }
        if ($null -ne $it.avg.gpu_power) { $parts += ('GPU ' + (Fmt $it.avg.gpu_power '0') + ' W') }
        if ($null -ne $it.avg.cpu_util) { $parts += ('CPU 占用 ' + (Fmt $it.avg.cpu_util '0') + ' %') }
        if ($null -ne $it.avg.cpu_temp) { $parts += ('CPU ' + (Fmt $it.avg.cpu_temp '0') + ' °C') }
        # 有样本但字段全空 = 这几项没开，不是「没采到样本」，两种说法不能混
        $sBody = if ($parts.Count -gt 0) { $parts -join ' · ' }
                 elseif ($it.samples -gt 0) { '本次没有采集这些指标（GPU / CPU 传感器未开启或不可用）' }
                 else { '窗口内没有可用的传感器样本' }
        $sRows += '<tr class="sec"><td colspan="2">#' + $si + ' · 位置 ' + (Fmt $it.at_pct '0.0') + '% · ' +
                  (Fmt $it.ms '0.0') + ' ms / ' + $it.frames + ' 帧</td></tr>' +
                  '<tr><td>前后 ±' + (Fmt $stutterCtx.window_seconds '0') + ' 秒平均（' + $it.samples + ' 个样本）</td><td>' + $sBody + '</td></tr>'
    }
    # 不再编号「02」：上面已经有 02 性能曲线，同一份报告里出现两个 02 会让人以为是重复章节
    $secStutter = '<h2>卡顿时刻</h2>' +
                  '<div class="cap">只列最严重的 ' + $si + ' 段。' + $alignTxt + '；不要把它当成精确到毫秒的因果证据。</div>' +
                  '<table class="det">' + $sRows + '</table>'
}

# ── B3：瓶颈诊断（结论 + 依据指标）──
$secDiag = ''
if ($diag) {
    $primMap = @{
        'gpu'      = @('GPU 瓶颈', '画面渲染时间占满帧时间，处理器一直在等显卡')
        'cpu'      = @('CPU 瓶颈', '处理器交付一帧的时间接近整帧时间')
        'balanced' = @('没有明显的单一瓶颈', 'CPU 与 GPU 都没吃满，帧率受别的东西（垂直同步 / 帧生成上限 / 引擎自身）牵制')
        'unknown'  = @('数据不足，暂不判定', '本次没拿到 CPU 帧处理时间或 GPU 负载，不硬猜')
    }
    $pm = if ($primMap.ContainsKey([string]$diag.primary)) { $primMap[[string]$diag.primary] } else { $primMap['unknown'] }
    $cls = if ($diag.level -eq 'warn') { 'warn' } else { 'good' }
    $rows = ''
    foreach ($e in @($diag.evidence)) {
        if ($null -eq $e) { continue }
        $rows += '<tr><td>' + $e.name + '</td><td>' + $e.value + '</td></tr>'
    }
    $findRows = ''
    foreach ($f in @($diag.findings)) {
        if ($null -eq $f) { continue }
        $findRows += '<tr><td>' + $f.name + '</td><td>' + $f.value + '</td></tr>'
    }
    $secDiag = '<h2>05 瓶颈诊断</h2>' + "`n" +
               '<div class="item ' + $cls + '"><div><b>' + $pm[0] + '</b> —— ' + $pm[1] + '</div></div>' + "`n" +
               '<table class="det">' + "`n" +
               '<tr class="sec"><td colspan="2">依据指标（全部来自本次采集）</td></tr>' + $rows + '</table>' + "`n"
    if ($findRows) {
        $secDiag += '<table class="det" style="margin-top:10px">' + "`n" +
                    '<tr class="sec"><td colspan="2">同时值得注意</td></tr>' + $findRows + '</table>' + "`n"
    }
}

# ── 详细数据：按指标字典的板块分组 ──
# 板块标题行（同一张表里用跨列的标题行分节，导出后直接可读）
function SecRow([string]$title) {
    return '<tr class="sec"><td colspan="2">' + $title + '</td></tr>'
}
# 字典里 status=na 的指标：数值写「—」，下一行写清楚为什么没有，
# 绝不用 0 或估算值占位（这是口径铁律）
function NaRows([string]$prefix) {
    $out = ''
    foreach ($n in $naMetrics) {
        if (-not ([string]$n.id).StartsWith($prefix + '.')) { continue }
        $out += '<tr class="narow"><td>' + $n.name + ' <span class="nabadge">暂不可用</span></td><td>—</td></tr>'
        if ($naReasons.ContainsKey($n.reason)) {
            $out += '<tr class="nawhy"><td colspan="2">' + $naReasons[$n.reason] + '</td></tr>'
        }
    }
    return $out
}
$detRows = ''
$detRows += SecRow '游戏性能表现'
$detRows += '<tr><td>帧时间 平均 / p95</td><td>' + (Fmt $summary.avg_frametime_ms '0.00') + ' ms / ' + (Fmt $summary.frametime_p95_ms '0.00') + ' ms</td></tr>'
$detRows += '<tr><td>帧时间 中位 / p99.9</td><td>' + (Fmt $summary.frametime_median_ms '0.00') + ' ms / ' + (Fmt $summary.frametime_p999_ms '0.00') + ' ms</td></tr>'
if ($null -ne $summary.frametime_stddev_ms) {
    $detRows += '<tr><td>帧时间抖动<br><span style="font-size:11.5px">标准差 / 变异系数，越小越稳</span></td><td>' + (Fmt $summary.frametime_stddev_ms '0.00') + ' ms / ' + (Fmt $summary.frametime_jitter_pct '0.0') + ' %</td></tr>'
}
$lf = $summary.long_frames
$detRows += '<tr><td>长帧分桶<br><span style="font-size:11.5px">&gt;2× / &gt;4× 中位（' + (Fmt $lf.base_ms '0.00') + ' ms）· &gt;50 / &gt;100 ms</span></td><td>' + $lf.over2x + ' / ' + $lf.over4x + ' / ' + $lf.over50 + ' / ' + $lf.over100 + ' 帧（' + (Fmt $lf.pct_over2x '0.00') + ' %）</td></tr>'
if ($null -ne $summary.displayed_fps) {
    $detRows += '<tr><td>上屏节奏 / 重复帧<br><span style="font-size:11.5px">DisplayedTime 间隔换算；重复帧 = 两帧落在同一上屏时刻</span></td><td>' + (Fmt $summary.displayed_fps '0.0') + ' FPS / ' + $summary.repeat_frames + ' 帧（' + (Fmt $summary.repeat_pct '0.00') + ' %）</td></tr>'
}
if ($null -ne $summary.sync_interval -or $null -ne $summary.present_flags) {
    $syncTxt = if ($null -ne $summary.sync_interval) { [string]$summary.sync_interval } else { 'NA' }
    $flagTxt = if ($null -ne $summary.present_flags) { [string]$summary.present_flags } else { 'NA' }
    $detRows += '<tr><td>同步间隔 / 呈现标志</td><td>SyncInterval ' + $syncTxt + ' · PresentFlags ' + $flagTxt + $(if ($null -ne $summary.allows_tearing_pct) { ' · 允许撕裂 ' + (Fmt $summary.allows_tearing_pct '0.0') + ' %' } else { '' }) + '</td></tr>'
}
if ($null -ne $summary.fps_1pct_low_time) {
    $detRows += '<tr><td>逐秒最低帧率（最差 1% 的秒）<br><span style="font-size:11.5px">只是参考序列，不参与判定；口径不同的两个数不再都叫 1% Low</span></td><td>' + (Fmt $summary.fps_1pct_low_time '0.0') + ' FPS（占平均 ' + (Fmt $summary.fps_1pct_low_time_pct '0.0') + ' %）</td></tr>'
}
if ($null -ne $summary.fps_01pct_low) {
    $detRows += '<tr><td>0.1% 低帧率<br><span style="font-size:11.5px">最差 0.1% 帧的平均帧时间换算（与 1% Low 同一口径）</span></td><td>' + (Fmt $summary.fps_01pct_low '0.0') + ' FPS</td></tr>'
}
if ($summary.stutter) {
    $detRows += '<tr><td>卡顿（单帧 &gt; ' + $summary.stutter_threshold_ms + ' ms，连续合并计段）<br><span style="font-size:11.5px">段数 / 累计 / 最长 / 严重帧（&gt;100ms）</span></td><td>' + $summary.stutter.count + ' 段 · ' + (Fmt $summary.stutter.total_ms '0.0') + ' ms · 最长 ' + (Fmt $summary.stutter.worst_ms '0.0') + ' ms · 严重 ' + $summary.stutter.severe + ' 帧</td></tr>'
}
if ($collectLatency) {
    $detRows += '<tr><td>上屏延迟 平均 / p95<br><span style="font-size:11.5px">生成好 → 被看到</span></td><td>' + (Fmt $summary.display_latency_avg_ms '0.00') + ' ms / ' + (Fmt $summary.display_latency_p95_ms '0.00') + ' ms</td></tr>'
}
if ($collectLatency) {
    $detRows += '<tr><td>PC 延迟（估算） 平均 / p95<br><span style="font-size:11.5px">平均帧时间 + 上屏延迟（估算值，非独立测量）</span></td><td>' + (Fmt $summary.pc_latency_avg_ms '0.00') + ' ms / ' + (Fmt $summary.pc_latency_p95_ms '0.00') + ' ms</td></tr>'
}
$detRows += NaRows 'perf'
$detRows += SecRow 'GPU 运行状态'
if ($collectGpuTemp) {
    $detRows += '<tr><td>GPU 温度 平均 / 最高</td><td>' + (Fmt $summary.gpu_temp_avg_c '0.0') + ' / ' + (Fmt $summary.gpu_temp_max_c '0.0') + ' °C</td></tr>'
}
if ($collectGpuUsage) {
    $detRows += '<tr><td>GPU 占用 平均 / 最高</td><td>' + (Fmt $summary.gpu_util_avg_pct '0.0') + ' / ' + (Fmt $summary.gpu_util_max_pct '0.0') + ' %</td></tr>'
}
if ($null -ne $summary.gpu_clock_avg_mhz) {
    $detRows += '<tr><td>GPU 频率 平均 / 最高<br><span style="font-size:11.5px">硬件上限 ' + (Fmt $summary.gpu_clock_hw_max_mhz '0') + ' MHz · 显存 ' + (Fmt $summary.gpu_mem_clock_avg_mhz '0') + ' MHz</span></td><td>' + (Fmt $summary.gpu_clock_avg_mhz '0') + ' / ' + (Fmt $summary.gpu_clock_max_mhz '0') + ' MHz</td></tr>'
}
if ($null -ne $summary.gpu_power_avg_w) {
    $detRows += '<tr><td>GPU 功耗 平均 / 最高' + $(if ($null -ne $summary.gpu_fan_avg_pct) { '<br><span style="font-size:11.5px">风扇 ' + (Fmt $summary.gpu_fan_avg_pct '0') + ' %</span>' } else { '' }) + '</td><td>' + (Fmt $summary.gpu_power_avg_w '0.0') + ' / ' + (Fmt $summary.gpu_power_max_w '0.0') + ' W</td></tr>'
}
if ($summary.pcie) {
    $detRows += '<tr><td>PCIe 链路</td><td>' + [string]$summary.pcie + '</td></tr>'
}
if ($summary.throttle.Count -gt 0) {
    $thrParts = @()
    foreach ($k in $summary.throttle.Keys) {
        $nm = if ($thrNames.Contains($k)) { $thrNames[$k] } else { $k }
        $thrParts += ($nm + ' ' + (Fmt $summary.throttle[$k] '0.0') + '%')
    }
    $detRows += '<tr><td>降频原因<br><span style="font-size:11.5px">采样点里处于该原因的比例</span></td><td>' + ($thrParts -join ' · ') + '</td></tr>'
} else {
    $detRows += '<tr><td>降频原因</td><td>采集期间未触发降频</td></tr>'
}
$detRows += NaRows 'gpu'
if ($summary.environment.gpu_vendor -and $summary.environment.gpu_vendor -ne 'nvidia') {
    $gvTxt = [string]$summary.environment.gpu_vendor
    $detRows += '<tr><td>GPU 指标</td><td>NA<span style="font-size:11.5px;color:#8a8a8a">（GPU 指标仅支持 NVIDIA 显卡；本机为 ' + $gvTxt + '）</span></td></tr>'
}
$detRows += SecRow 'CPU 运行状态'
if ($null -ne $summary.cpu_util_avg_pct) {
    $detRows += '<tr><td>CPU 占用 平均 / 最高' + $(if ($null -ne $summary.cpu_max_core_avg_pct) { '<br><span style="font-size:11.5px">最高单核 ' + (Fmt $summary.cpu_max_core_avg_pct '0.0') + ' %（峰值 ' + (Fmt $summary.cpu_max_core_peak_pct '0.0') + ' %）</span>' } else { '' }) + '</td><td>' + (Fmt $summary.cpu_util_avg_pct '0.0') + ' / ' + (Fmt $summary.cpu_util_max_pct '0.0') + ' %</td></tr>'
}
if ($null -ne $summary.cpu_extra.pkg_power_avg_w) {
    $detRows += '<tr><td>CPU 封装功耗 平均 / 峰值<br><span style="font-size:11.5px">含核显与 uncore，不是单核功耗</span></td><td>' + (Fmt $summary.cpu_extra.pkg_power_avg_w '0.0') + ' / ' + (Fmt $summary.cpu_extra.pkg_power_max_w '0.0') + ' W</td></tr>'
} elseif ($collectCpuPower) {
    $detRows += '<tr><td>CPU 封装功耗</td><td>NA<span style="font-size:11.5px;color:#8a8a8a">（这台机器没有提供 CPU 能量计数器）</span></td></tr>'
}
# CPU 温度：有值就报数值 + 来源；没有就给具体原因，不藏行、不填 0（规则文档 §5）
$ct = $summary.cpu_thermal
$tmpSrcLabel = switch -Regex ([string]$ct.temp_source) {
    'lenovo' { '联想固件通道' }
    '^vendor-wmi' { '厂商固件通道' }
    default { [string]$ct.temp_source }
}
if ($null -ne $ct.temp_max_c) {
    $detRows += '<tr><td>CPU 温度 平均 / 最高<br><span style="font-size:11.5px">来源：' + $tmpSrcLabel + '（只读固件接口，不是主板/机箱热区）</span></td><td>' + (Fmt $ct.temp_avg_c '0.0') + ' / ' + (Fmt $ct.temp_max_c '0') + ' °C</td></tr>'
} else {
    $whyTmp = ''
    if (Get-Command Get-PlatformReasonText -ErrorAction SilentlyContinue) { $whyTmp = Get-PlatformReasonText ([string]$ct.temp_reason) }
    if (-not $whyTmp) { $whyTmp = '这台机器没有可用的固件温度通道' }
    $detRows += '<tr><td>CPU 温度</td><td>NA<span style="font-size:11.5px;color:#8a8a8a">（' + $whyTmp + '）</span></td></tr>'
}
# CPU 降频：Windows 事件日志 Event 37，只报「固件限速记录」，不做原因归因
if ($ct.throttle_ok) {
    if ($ct.throttle_count -gt 0) {
        $thrTxt = '已记录 ' + $ct.throttle_count + ' 条'
        if ($ct.throttle_cores -gt 0) { $thrTxt += '（涉及 ' + $ct.throttle_cores + ' 个逻辑处理器' }
        if ($null -ne $ct.throttle_max_s) {
            if ($ct.throttle_cores -gt 0) { $thrTxt += '，最长一次 ' + $ct.throttle_max_s + ' 秒）' }
            else { $thrTxt += '（最长一次 ' + $ct.throttle_max_s + ' 秒）' }
        } elseif ($ct.throttle_cores -gt 0) { $thrTxt += '）' }
        $detRows += '<tr><td>CPU 降频（固件限速）<br><span style="font-size:11.5px">Windows 系统日志 Event 37：只说明被固件限制，不指明原因</span></td><td>' + $thrTxt + '</td></tr>'
    } else {
        $detRows += '<tr><td>CPU 降频（固件限速）<br><span style="font-size:11.5px">Windows 系统日志 Event 37</span></td><td>采集期间未记录到固件限速</td></tr>'
    }
} else {
    $detRows += '<tr><td>CPU 降频（固件限速）</td><td>NA<span style="font-size:11.5px;color:#8a8a8a">（Windows 系统日志不可读）</span></td></tr>'
}
$detRows += NaRows 'cpu'
# 平台覆盖（规则文档 §1）：表外组合明确写「不支持」，不因为值为空就把整行藏掉
if ($summary.environment.cpu_vendor -and $summary.environment.cpu_vendor -notin @('intel', 'amd')) {
    $detRows += '<tr><td>CPU 指标</td><td>NA<span style="font-size:11.5px;color:#8a8a8a">（仅支持 Intel / AMD 处理器；本机厂商未在覆盖范围内）</span></td></tr>'
}
$detRows += SecRow '内存与显存'
if ($collectVram) {
    $detRows += '<tr><td>显存 平均 / 最高（本程序）</td><td>' + (Fmt $summary.vram_avg_mb '0') + ' / ' + (Fmt $summary.vram_max_mb '0') + ' MB</td></tr>'
}
if ($collectShared -and $null -ne $summary.memory.shared_vram_max_mb) {
    $detRows += '<tr><td>共享 GPU 内存（目标游戏所在显卡）</td><td>平均 ' + (Fmt $summary.memory.shared_vram_avg_mb '0') + ' / 最高 ' + (Fmt $summary.memory.shared_vram_max_mb '0') + ' MB</td></tr>'
} elseif ($collectShared) {
    $detRows += '<tr><td>共享 GPU 内存</td><td>NA<span style="font-size:11.5px;color:#8a8a8a">（目标游戏未出现在显卡计数器实例中）</span></td></tr>'
}
if ($collectRam) {
    $detRows += '<tr><td>内存 平均 / 最高（本程序）</td><td>' + (Fmt $summary.ram_avg_mb '0') + ' / ' + (Fmt $summary.ram_max_mb '0') + ' MB</td></tr>'
}
$detRows += NaRows 'mem'
$detRows += SecRow '功耗与温控'
$detRows += NaRows 'thermal'
$detRows += SecRow '渲染瓶颈分析'
$detRows += NaRows 'bottleneck'
$detRows += SecRow '测试环境'
# 平台覆盖：跨机器对比时，先确认双方都在支持矩阵内（规则文档 §1）
$platParts = @()
if ($summary.environment.cpu_vendor) { $platParts += ('CPU ' + $summary.environment.cpu_vendor) }
if ($summary.environment.gpu_vendor) { $platParts += ('GPU ' + $summary.environment.gpu_vendor) }
if ($summary.environment.system_vendor) {
    $sysTxt = [string]$summary.environment.system_vendor
    if ($summary.environment.system_model) { $sysTxt += ' ' + $summary.environment.system_model }
    $platParts += ('整机 ' + $sysTxt)
}
if ($platParts.Count -gt 0) {
    $detRows += '<tr><td>平台</td><td>' + ($platParts -join ' · ') + '</td></tr>'
}
# 帧数据源：同一次采集只有一个来源，报告必须如实标注（2.1.10）
$srcLabel = if ($FpsSource -eq 'presentmon') { 'PresentMon ETW（零注入基线）' } else { $FpsSource + '（扩展数据源）' }
$detRows += '<tr><td>帧数据源</td><td>' + $srcLabel + '</td></tr>'
# 条件指纹（2.1.13）：这三行是「两次报告能不能直接比」的前提，缺一项就少一个可比性依据
if ($summary.environment.os_version) {
    $osTxt = [string]$summary.environment.os_version
    if ($summary.environment.os_build) { $osTxt += '（Build ' + $summary.environment.os_build + '）' }
    $detRows += '<tr><td>操作系统</td><td>' + $osTxt + '</td></tr>'
}
if ($summary.environment.bios_version) {
    $detRows += '<tr><td>BIOS</td><td>' + [string]$summary.environment.bios_version + '</td></tr>'
}
if ($summary.environment.driver_version) {
    $detRows += '<tr><td>显卡驱动</td><td>' + [string]$summary.environment.driver_version + '</td></tr>'
} else {
    $detRows += '<tr><td>显卡驱动</td><td>未知<span style="font-size:11.5px;color:#8a8a8a">（nvidia-smi 未返回驱动版本）</span></td></tr>'
}
if ($collectRes -and $summary.resolution) {
    $detRows += '<tr><td>分辨率 / 窗口模式</td><td>' + ($summary.resolution -replace 'x', '×') + ' / ' + $summary.window_mode + '</td></tr>'
    if ($summary.monitor) { $detRows += '<tr><td>显示器分辨率</td><td>' + ($summary.monitor -replace 'x', '×') + '</td></tr>' }
}
if ($summary.present_mode) { $detRows += '<tr><td>呈现模式</td><td>' + $summary.present_mode + '</td></tr>' }
$detRows += '<tr><td>采集完整度</td><td>有效 ' + $summary.captured_seconds + 's / 采集 ' + $summary.wall_seconds + 's</td></tr>'
# 供电侧的全部数据都放在 07 测试环境（属于「这次的现场条件」，不是性能指标）
$detRows += '<tr><td>供电状态（采集期间）</td><td>' + $pwSrcTxt + '</td></tr>'
if ($null -ne $summary.environment.gpu_limit_max_w) {
    $limTxt = if ($summary.environment.gpu_limit_min_w -eq $summary.environment.gpu_limit_max_w) {
        (Fmt $summary.environment.gpu_limit_max_w '0.0') + ' W'
    } else {
        (Fmt $summary.environment.gpu_limit_min_w '0.0') + ' – ' + (Fmt $summary.environment.gpu_limit_max_w '0.0') + ' W'
    }
    $detRows += '<tr><td>显卡功耗上限（生效值）<br><span style="font-size:11.5px">驱动/厂商按供电与性能模式给的功率预算，不是瞬时功耗</span></td><td>' + $limTxt + '</td></tr>'
}
if ($summary.environment.battery_present) {
    $detRows += '<tr><td>电池电量（采集期间）</td><td>' + (Fmt $summary.environment.battery_min_pct '0') + ' – ' + (Fmt $summary.environment.battery_max_pct '0') + ' %</td></tr>'
}
if ($null -ne $summary.environment.power_events) {
    $detRows += '<tr><td>采集期间电源中断</td><td>' + $(if ($summary.environment.power_events -eq 0) { '0 次' } else { [string]$summary.environment.power_events + ' 次（Kernel-Power 105）' }) + '</td></tr>'
}
if ($summary.environment.power_health) {
    $detRows += '<tr><td>近 24 小时异常关机 / 硬件错误</td><td>' + $(if ($summary.environment.power_health -eq 'ok') { '无' } else { [string]$summary.environment.power_health_detail }) + '</td></tr>'
}
$detRows += NaRows 'env'

# ── B3：把详细数据按 01–07 的板块顺序重排 ──
# $detRows 里每节都以 <tr class="sec"> 开头，这里按标记切块再按目标顺序拼回去，
# 行内容一行都不用改；编号与界面报告一致：03 CPU/GPU、04 内存、06 完整明细、07 测试环境。
$secParts = @{}
foreach ($p in [regex]::Split($detRows, '(?=<tr class="sec">)')) {
    $mm = [regex]::Match($p, '<tr class="sec"><td colspan="2">([^<]+)</td></tr>')
    if ($mm.Success) {
        $secParts[$mm.Groups[1].Value] = ($p -replace '^\s*<tr class="sec"><td colspan="2">[^<]+</td></tr>', '')
    } else {
        $secParts[''] = $p
    }
}
function TakeSec($parts, [string]$key, [string]$title) {
    if (-not $parts.ContainsKey($key)) { return '' }
    $body = $parts[$key]
    if (-not $body) { return '' }
    if (-not $title) { return $body }
    return '<tr class="sec"><td colspan="2">' + $title + '</td></tr>' + $body
}
$detOrdered = (TakeSec $secParts '' '') +
              (TakeSec $secParts 'CPU 运行状态' '03 CPU / GPU 状态') +
              (TakeSec $secParts 'GPU 运行状态' '') +
              (TakeSec $secParts '内存与显存' '04 内存资源') +
              (TakeSec $secParts '游戏性能表现' '06 完整明细 · 性能表现') +
              (TakeSec $secParts '功耗与温控' '06 完整明细 · 功耗与温控') +
              (TakeSec $secParts '渲染瓶颈分析' '06 完整明细 · 渲染瓶颈分析') +
              (TakeSec $secParts '测试环境' '07 测试环境')

# 页头 / 页脚
$apiText2 = if ($apiName -eq 'DXGI') { 'DirectX' } elseif ($apiName -eq 'Vulkan') { 'Vulkan' } elseif ($apiName -and $apiName -ne 'Unknown') { $apiName } else { '' }
$metaParts = @($exeBase, ('PID ' + $GamePid))
if ($collectRes -and $summary.resolution) { $metaParts += ('<b>' + ($summary.resolution -replace 'x', '×') + ' / ' + $summary.window_mode + '</b>') }
if ($collectFeatures -and $apiText2) { $metaParts += ('后端 <b>' + $apiText2 + '</b>') }
$metaHtml = $metaParts -join ' · '

$fgPctText = if ($null -ne $summary.foreground_pct) { $summary.foreground_pct.ToString() + '%' } else { 'NA' }

$skipNames = @()
if (-not $collectLatency)   { $skipNames += '上屏延迟' }
if (-not $collectProcCpu)   { $skipNames += '游戏进程 CPU' }
if (-not $collectCpuPower)  { $skipNames += 'CPU 封装功耗' }
if (-not $collectGpuTemp)   { $skipNames += 'GPU 温度 / 功耗' }
if (-not $collectGpuUsage)  { $skipNames += 'GPU 占用 / 频率' }
if (-not $collectVram)      { $skipNames += '显存' }
if (-not $collectRam)       { $skipNames += '内存' }
if (-not $collectSysMem)    { $skipNames += '系统内存' }
if (-not $collectShared)    { $skipNames += '共享显存' }
if (-not $collectFeatures)  { $skipNames += '图显特性' }
if (-not $collectRes)       { $skipNames += '分辨率' }
if (-not $collectChart)     { $skipNames += '帧时间曲线' }
$skipNote = ''
if ($skipNames.Count -gt 0) { $skipNote = '本次未采集：' + ($skipNames -join '、') + '。<br>' }

# ── 数据可信度横幅（2.1.13）──
# 只在确实有问题时出现：ok 不显示，避免每份报告都多一条无信息量的横幅。
# 措辞只说明「影响了什么」，不下「数据完全不可用」这种一刀切结论。
$qualHtml = ''
$qChecks = @()
if ($quality -and $quality.checks) { $qChecks = @($quality.checks) }
if ($qChecks.Count -gt 0) {
    $qBlocked = ([string]$quality.level -eq 'blocked')
    $qCls = if ($qBlocked) { 'bad' } else { 'warn' }
    $qTitle = if ($qBlocked) { '本次数据不足以支撑结论' } else { '本次数据可用，但有以下情况需要注意' }
    $qLines = ''
    foreach ($c in $qChecks) {
        switch ([string]$c.code) {
            'fewSamples' { $qLines += '<div>· 只采到 <b>' + $c.frames + '</b> 帧 / <b>' + $c.seconds + '</b> 秒：1% Low 与卡顿统计不可靠，不建议据此对比或下结论。</div>' }
            'stalled'    { $qLines += '<div>· 采集被中断：游戏停止出帧，统计只覆盖前半段。</div>' }
            'partial'    { $qLines += '<div>· 有效时长只占采集窗口的 <b>' + $c.pct + '%</b>：中间有停帧，数值偏乐观。</div>' }
            'targetLost' { $qLines += '<div>· 有 <b>' + $c.pct + '%</b> 的采样时间游戏不在前台：画面可能被其它窗口干扰。</div>' }
            'gpuSparse'  { $qLines += '<div>· GPU 指标只有 <b>' + $c.pct + '%</b> 的采样取到：GPU 相关结论请谨慎。</div>' }
            default      { $qLines += '<div>· ' + [string]$c.code + '</div>' }
        }
    }
    $qualHtml = '<div class="item ' + $qCls + '"><div><b>' + $qTitle + '</b>' + $qLines + '</div></div>' + "`n"
}

$html = @"
<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>游戏性能报告 - $runName</title>
<style>
*{box-sizing:border-box}
body{margin:0;padding:32px 24px;background:$cPage;color:$cText;font:14px/1.65 'Segoe UI','Microsoft YaHei UI',sans-serif}
.wrap{max-width:1000px;margin:0 auto}
header{display:flex;justify-content:space-between;align-items:flex-end;gap:20px;border-bottom:1px solid $cLine;padding-bottom:16px;margin-bottom:22px;flex-wrap:wrap}
h1{font-size:21px;margin:0 0 6px;font-weight:600;color:$cStrong}
.meta{color:$cMuted;font-size:12.5px}
.meta b{color:$cStrong;font-weight:600}
.mins{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin:0 0 8px}
@media (max-width:760px){.mins{grid-template-columns:1fr}}
.mini{background:$cPanel;border:1px solid $cLine;border-radius:10px;padding:10px 12px 8px;box-shadow:$cCardSh}
.mini .minit{font-size:12px;color:$cMuted;margin-bottom:6px}
.chapt{font-size:12.5px;color:$cMuted;font-weight:600;margin:14px 0 8px;letter-spacing:.3px}
.mini svg{display:block;width:100%;height:96px;overflow:visible}
.mini .cap{color:$cFaint;font-size:11px;margin-top:6px}
.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}
@media (max-width:760px){body{padding:20px 14px}.grid{grid-template-columns:repeat(2,1fr)}td.fs{display:none}}
.card{background:$cPanel;border:1px solid $cLine;border-radius:10px;padding:14px 16px;box-shadow:$cCardSh}
.card .k{color:$cMuted;font-size:12px;margin-bottom:8px}
.card .v{font-size:25px;font-weight:600;font-variant-numeric:tabular-nums;letter-spacing:-.5px;color:$cStrong}
.card .u{font-size:12px;color:$cMuted;margin-left:5px;font-weight:400}
/* 1% Low 右侧的占比：与单位（FPS）同样的字号与颜色，不是数值那种大字 */
.card .p{font-size:12px;color:$cMuted;margin-left:5px;font-weight:400}
.card .s{color:$cFaint;font-size:11.5px;margin-top:5px}
h2{font-size:13px;color:$cMuted;font-weight:600;margin:28px 0 10px;letter-spacing:.6px}
.item{display:flex;align-items:flex-start;gap:0;background:$cPanel;border:1px solid $cLine;border-left:3px solid $cLine;border-radius:8px;padding:11px 15px;margin-bottom:8px;font-size:13.5px;box-shadow:$cCardSh}
.item.good{border-left-color:$cGood}
.item.warn{border-left-color:$cWarn}
.item.bad{border-left-color:$cBad}
.chartbox{background:$cPanel;border:1px solid $cLine;border-radius:10px;padding:18px 18px 10px;box-shadow:$cCardSh}
.chartwrap{display:flex;gap:12px}
.chart{position:relative;flex:1;min-width:0;height:150px}
.chart svg{position:absolute;inset:0;width:100%;height:100%;display:block;overflow:visible}
.ylab{position:relative;width:46px;flex:none}
.ylab span{position:absolute;right:0;transform:translateY(-50%);font-size:11px;color:$cFaint;font-variant-numeric:tabular-nums;white-space:nowrap}
.cap{color:$cFaint;font-size:12px;margin-top:10px}
table{width:100%;border-collapse:collapse;background:$cPanel;border:1px solid $cLine;border-radius:10px;overflow:hidden;box-shadow:$cCardSh}
td{padding:9px 14px;border-bottom:1px solid $cLine;font-size:13.5px}
tr:last-child td{border-bottom:none}
td.fk{color:$cMuted;width:32%}
td.fv{font-weight:600;color:$cStrong}
td.fs{color:$cFaint;font-size:12px;text-align:right}
.det td:first-child{color:$cMuted}
.det tr.sec td{background:$cLine;color:$cMuted;font-size:12px;font-weight:600;letter-spacing:.4px;padding:6px 14px;text-align:left}
.det tr.narow td:first-child{color:$cMuted}
.det tr.narow td:last-child{color:$cFaint;text-align:right}
.nabadge{display:inline-block;margin-left:6px;padding:0 7px;border:1px solid $cWarn;border-radius:999px;font-size:10.5px;line-height:1.6;color:$cWarn;vertical-align:1px}
.det tr.nawhy td{color:$cFaint;font-size:11.5px;line-height:1.6;padding:0 14px 9px;border-bottom:1px solid $cLine;text-align:left}
.det td:last-child{text-align:right;font-variant-numeric:tabular-nums}
footer{margin-top:26px;padding-top:14px;border-top:1px solid $cLine;color:$cFaint;font-size:12px;line-height:1.8}
code{background:$cCodeBg;padding:1px 5px;border-radius:4px;color:$cText}
</style></head><body><div class="wrap">
<header>
  <div>
    <h1>游戏性能报告</h1>
    <div class="meta">$metaHtml</div>
  </div>
  <div class="meta" style="text-align:right">
    $runName<br>
    采集 <b>$($summary.captured_seconds)s</b> / $($summary.frames) 帧 · 前台 <b>$fgPctText</b>
  </div>
</header>
$qualHtml
<div class="grid">
$cards</div>

<h2>01 概览</h2>
$verdictItems
<h2>02 性能曲线</h2>
$secChart$secTrend
$secStutter
$secDiag
<table class="det">
$detOrdered
</table>
$secFeatures

<footer>
${skipNote}数据来源：Intel PresentMon 2.6（ETW，不注入游戏进程）取 FPS / 1% Low / 帧时间 / 上屏延迟；nvidia-smi 取 GPU 占用与温度；
GPU Process Memory 计数器取本程序显存；Get-Process 取本程序内存；分辨率取自游戏窗口客户区。<br>
1% Low = 最慢 1% 帧的平均帧时间换算 FPS；PC 延迟 = 帧生成时间 + 上屏延迟，即「开始生成这一帧 → 被看到」的整段时间；<br>
上屏延迟 = 生成好的帧 到 它在屏幕上被看到 的时间（DisplayLatency，帧提交 → 扫描输出）；<br>
原始数据：<code>$pmCsv</code> · <code>$sensCsv</code>
</footer>
</div></body></html>
"@
$html | Out-File -FilePath $htmlOut -Encoding UTF8

Write-Host ''
Write-Host ("HTML report : " + $htmlOut) -ForegroundColor Green
Write-Host ("Raw CSV     : " + $pmCsv)
Write-Host ("Sensors CSV : " + $sensCsv)
Write-Host ("JSON summary: " + $jsonOut)
Pause-End 'Press Enter to close'
