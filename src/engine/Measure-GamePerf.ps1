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
    [string]$HtmlPath = ''
)

# ---------------------------------------------------------------- collection switches
# -Skip latency,gputemp,gpuusage,vram,ram,features,res  (empty = collect everything)
# 旧配置兼容：gpu = gputemp + gpuusage；mem = vram + ram（1.2 及更早只有这两个粗开关）
if ($Theme -ne 'light') { $Theme = 'dark' }
$skipList = @()
foreach ($k in ($Skip -split ',')) { $k = $k.Trim().ToLower(); if ($k) { $skipList += $k } }
if ($skipList -contains 'gpu') { $skipList += 'gputemp', 'gpuusage' }
if ($skipList -contains 'mem') { $skipList += 'vram', 'ram' }
$collectLatency  = -not ($skipList -contains 'latency')
$collectGpuTemp  = -not ($skipList -contains 'gputemp')
$collectGpuUsage = -not ($skipList -contains 'gpuusage')
$collectVram     = -not ($skipList -contains 'vram')
$collectRam      = -not ($skipList -contains 'ram')
$collectFeatures = -not ($skipList -contains 'features')
$collectRes      = -not ($skipList -contains 'res')
$collectChart    = $true      # 图表始终生成：UI 不再提供开关，报告里必定含曲线
$collectGpuSensors = $collectGpuTemp -or $collectGpuUsage   # 两者共用一次 nvidia-smi 查询
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- elevation
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $ps = (Get-Process -Id $PID).Path
    if (-not $ps) { $ps = 'powershell.exe' }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Seconds', $Seconds, '-Countdown', $Countdown, '-ProcessId', $ProcessId, '-ProcessName', ('"' + $ProcessName + '"'), '-Label', ('"' + $Label + '"'), '-OutDir', ('"' + $OutDir + '"'))
    if ($Skip) { $argList += @('-Skip', ('"' + $Skip + '"')) }
    $argList += @('-Theme', $Theme)
    if ($HtmlPath) { $argList += @('-HtmlPath', ('"' + $HtmlPath + '"')) }
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
$sampler = Start-Job -ArgumentList $GamePid, $sensCsv, ($Seconds + 10), $smi, $collectGpuSensors, $collectVram, $collectRam -ScriptBlock {
    param($gpid, $csv, $maxSec, $smi, $wantGpu, $wantVram, $wantRam)
    if (-not ($wantGpu -or $wantVram -or $wantRam)) { return }
    $script:t0 = Get-Date
    'timestamp_utc,gpu_temp_c,gpu_util_pct,gpu_mem_used_mb,proc_vram_mb,proc_ram_mb' | Out-File -FilePath $csv -Encoding ASCII
    while (((Get-Date) - $script:t0).TotalSeconds -lt $maxSec) {
        $ts = (Get-Date).ToString('HH:mm:ss')
        $temp = 'NA'; $util = 'NA'; $mem = 'NA'
        # 温度与占用来自同一次 nvidia-smi 查询，分开开关只在汇总时区分
        if ($wantGpu -and (Test-Path $smi)) {
            try {
                $q = & $smi --query-gpu=temperature.gpu,utilization.gpu,memory.used --format=csv,noheader,nounits 2>$null
                if ($q) { $p = ($q -split ',') | ForEach-Object { $_.Trim() }; $temp = $p[0]; $util = $p[1]; $mem = $p[2] }
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
        $ram = 'NA'
        if ($wantRam) {
            try { $pr = Get-Process -Id $gpid -ErrorAction Stop; $ram = [math]::Round($pr.WorkingSet64 / 1MB, 0) } catch { }
        }
        ($ts + ',' + $temp + ',' + $util + ',' + $mem + ',' + $vram + ',' + $ram) | Out-File -FilePath $csv -Append -Encoding ASCII
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

$frameTimes = New-Object System.Collections.Generic.List[double]
$dispLat    = New-Object System.Collections.Generic.List[double]
$inLat      = New-Object System.Collections.Generic.List[double]

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

for ($ln = 1; $ln -lt $csvLines.Count; $ln++) {
    $f = $csvLines[$ln] -split ','
    if ($f.Count -ne $colCount) { continue }
    $isMe = $false
    if ($iPid -ge 0 -and $f[$iPid] -eq "$GamePid") { $isMe = $true }
    if (-not $isMe -and $iApp -ge 0 -and $f[$iApp] -eq ($exeBase + '.exe')) { $isMe = $true }
    if (-not $isMe) { continue }
    if ($iFt -ge 0) {
        $ft = 0.0
        if ([double]::TryParse($f[$iFt], [ref]$ft) -and $ft -gt 0) { $frameTimes.Add($ft) }
    }
    if ($iDl -ge 0) {
        $dl = 0.0
        if ([double]::TryParse($f[$iDl], [ref]$dl) -and $dl -gt 0) { $dispLat.Add($dl) }
    }
    if ($iCl -ge 0) {
        $cl = 0.0
        if ([double]::TryParse($f[$iCl], [ref]$cl) -and $cl -gt 0) { $inLat.Add($cl) }
    }
}

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
# 1% Low：先丢掉最差的那一帧（一次卡顿尖峰不该定义整个下限），再取剩余帧里最差 1% 的平均。
$trimmed   = if ($sorted.Count -gt 20) { @($sorted | Select-Object -Skip 1) } else { $sorted }
$n1        = [math]::Max(1, [int][math]::Ceiling($trimmed.Count * 0.01))
$slowest1  = ($trimmed | Select-Object -First $n1 | Measure-Object -Average).Average
$fps1Low   = 1000.0 / $slowest1
$ftP95     = Get-Percentile $frameTimes 0.95

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
    $chartLimit = [math]::Ceiling([math]::Max([math]::Max($ftP999, $ftP95b * 1.15), 8.0) * 2.0) / 2.0
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

# 帧率落回 1% Low **附近**的频率：按图表同一套时间桶，统计有多少桶的平均帧率
# 落在 1% Low 的「附近 10%」以内（≤ 1% Low × 1.10）。比 1% Low 更差的桶自然也在其中。
# "偶尔掉一次"和"反复掉"是偶发卡顿与帧率不稳的区别，这也是 1% Low 判定的新依据
# （占平均的百分比只用于展示，不再作为判定门槛）。
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

function Fmt($v, [string]$fmt = '0.0') { if ($null -eq $v) { return 'NA' } return ([string]::Format([cultureinfo]::InvariantCulture, '{0:' + $fmt + '}', $v)) }

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

if ($modState -eq 'ok') {
    $jmods = ' ' + ($modList -join ' ')
    [void]$features.Add(@('feature.dlss.upscale', $(if ($jmods -match '(?i)nvngx_dlss\.dll') { 'value.loaded' } else { 'value.notLoaded' }), '模块 nvngx_dlss.dll'))
    [void]$features.Add(@('feature.dlss.framegen', $(if ($jmods -match '(?i)nvngx_dlssg\.dll') { 'value.loaded' } else { 'value.notLoaded' }), '模块 nvngx_dlssg.dll'))
    [void]$features.Add(@('feature.dlss.rayReconstruction', $(if ($jmods -match '(?i)nvngx_dlssd\.dll') { 'value.loaded' } else { 'value.notLoaded' }), '仅光追时加载'))
    [void]$features.Add(@('feature.fsr', $(if ($jmods -match '(?i)fidelityfx|ffx_') { 'value.loaded' } else { 'value.notLoaded' }), 'AMD FidelityFX'))
    [void]$features.Add(@('feature.xess', $(if ($jmods -match '(?i)libxess') { 'value.loaded' } else { 'value.notLoaded' }), 'Intel XeSS'))
} else {
    $why = if ($modState -eq 'blocked') { '进程受反作弊保护，外部无法枚举模块' } else { '读取模块失败' }
    [void]$features.Add(@('feature.upscalers', 'value.unavailable', $why))
}

$fgOn = $false
$pfKey = 'HKCU:\SOFTWARE\Hypergryph\Endfield'
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
    } catch { }
}

}
# ---------------------------------------------------------------- verdicts
$verdicts = New-Object System.Collections.ArrayList
if ($avgFPS -ge 120) { [void]$verdicts.Add(@('good', 'verdict.fps.excellent', @{ fps = [math]::Round($avgFPS,1) })) }
elseif ($avgFPS -ge 60) { [void]$verdicts.Add(@('good', 'verdict.fps.base60', @{ fps = [math]::Round($avgFPS,1) })) }
elseif ($avgFPS -ge 45) { [void]$verdicts.Add(@('warn', 'verdict.fps.low', @{ fps = [math]::Round($avgFPS,1) })) }
else { [void]$verdicts.Add(@('bad', 'verdict.fps.poor', @{ fps = [math]::Round($avgFPS,1) })) }

# 1% Low 判定：不看"占平均帧率多少"（那个太严，240 FPS 的机器也会被判不稳），
# 改看"多久掉回这个水平一次"——落回频率才是帧率稳不稳的直接证据。
if ($lowHitsPct -le 3) { [void]$verdicts.Add(@('good', 'verdict.low.smooth', @{ n = $lowHitsPct })) }
elseif ($lowHitsPct -le 10) { [void]$verdicts.Add(@('warn', 'verdict.low.occasional', @{ n = $lowHitsPct })) }
else { [void]$verdicts.Add(@('bad', 'verdict.low.frequent', @{ n = $lowHitsPct })) }

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
$summary = [ordered]@{
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
    pc_latency_avg_ms  = if ($null -ne $pcLatAvg) { [math]::Round($pcLatAvg, 2) } else { $null }
    pc_latency_p95_ms  = if ($null -ne $pcLatP95) { [math]::Round($pcLatP95, 2) } else { $null }
    chart            = if ($chartMs -and $chartMs.Count -gt 0) { [ordered]@{ per_bin = $chartPerBin; limit = $chartLimit; over = $chartOver; ms = @($chartMs); avg = @($chartAvg) } } else { $null }
    features         = @($features)
    verdicts         = @($verdicts)
    collected        = [ordered]@{ latency = $collectLatency; gputemp = $collectGpuTemp; gpuusage = $collectGpuUsage; vram = $collectVram; ram = $collectRam; features = $collectFeatures; res = $collectRes; chart = $collectChart }
}
$summary | ConvertTo-Json -Depth 3 | Out-File -FilePath $jsonOut -Encoding UTF8

# ---------------------------------------------------------------- console output
Write-Host ''
Write-Host '================ RESULT ================' -ForegroundColor Cyan
Write-Host ("  captured        : " + $summary.captured_seconds + " s / " + $summary.frames + " frames")
Write-Host ("  avg FPS         : " + $summary.avg_fps)
Write-Host ("  1% low FPS      : " + $summary.fps_1pct_low + "  (占平均 " + $summary.fps_1pct_low_pct + "%, 落回 1% Low 附近 " + $summary.low_hits_pct + "% 的时间)")
Write-Host ("  avg frame time  : " + $summary.avg_frametime_ms + " ms  (p95 " + $summary.frametime_p95_ms + " ms)")
Write-Host ("  display latency : " + $(if ($null -ne $summary.display_latency_avg_ms) { "" + $summary.display_latency_avg_ms + " ms (p95 " + $summary.display_latency_p95_ms + " ms)" } else { "NA" }))
Write-Host ("  GPU usage       : " + $(if ($null -ne $summary.gpu_util_avg_pct) { "" + $summary.gpu_util_avg_pct + " % (max " + $summary.gpu_util_max_pct + " %)" } else { "NA" }))
Write-Host ("  GPU temp        : " + $(if ($null -ne $summary.gpu_temp_avg_c) { "" + $summary.gpu_temp_avg_c + " C (max " + $summary.gpu_temp_max_c + " C)" } else { "NA" }))
Write-Host ("  VRAM (this app) : " + $(if ($null -ne $summary.vram_avg_mb) { "" + $summary.vram_avg_mb + " MB (max " + $summary.vram_max_mb + " MB)" } else { "NA" }))
Write-Host ("  RAM  (this app) : " + $(if ($null -ne $summary.ram_avg_mb) { "" + $summary.ram_avg_mb + " MB (max " + $summary.ram_max_mb + " MB)" } else { "NA" }))
Write-Host ("  PC latency      : " + $(if ($null -ne $summary.pc_latency_avg_ms) { "" + $summary.pc_latency_avg_ms + " ms (frame gen + display, p95 " + $summary.pc_latency_p95_ms + " ms)" } else { "NA" }))
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
    $cards += Card 'PC 延迟' $(if ($null -ne $summary.pc_latency_avg_ms) { (Fmt $summary.pc_latency_avg_ms '0.0') } else { 'NA' }) 'ms' '生成时间 + 上屏延迟'
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
    $secChart = '<h2>帧时间</h2>' + "`n" + '<div class="chartbox">' + "`n" +
                '<div class="chartwrap"><div class="chart">' + $chartSvg + '</div><div class="ylab">' + $chartYlab + '</div></div>' + "`n" +
                '<div class="cap">' + $chartCap + '</div>' + "`n" + '</div>' + "`n"
}
$secFeatures = ''
if ($featureRows) {
    $secFeatures = '<h2>图显特性</h2>' + "`n" + '<table>' + "`n" + $featureRows + '</table>' + "`n"
}

$detRows = ''
$detRows += '<tr><td>帧时间 平均 / p95</td><td>' + (Fmt $summary.avg_frametime_ms '0.00') + ' ms / ' + (Fmt $summary.frametime_p95_ms '0.00') + ' ms</td></tr>'
if ($collectLatency) {
    $detRows += '<tr><td>上屏延迟 平均 / p95<br><span style="font-size:11.5px">生成好 → 被看到</span></td><td>' + (Fmt $summary.display_latency_avg_ms '0.00') + ' ms / ' + (Fmt $summary.display_latency_p95_ms '0.00') + ' ms</td></tr>'
}
if ($collectLatency) {
    $detRows += '<tr><td>PC 延迟 平均 / p95<br><span style="font-size:11.5px">生成时间 + 上屏延迟</span></td><td>' + (Fmt $summary.pc_latency_avg_ms '0.00') + ' ms / ' + (Fmt $summary.pc_latency_p95_ms '0.00') + ' ms</td></tr>'
}
if ($collectGpuTemp) {
    $detRows += '<tr><td>GPU 温度 平均 / 最高</td><td>' + (Fmt $summary.gpu_temp_avg_c '0.0') + ' / ' + (Fmt $summary.gpu_temp_max_c '0.0') + ' °C</td></tr>'
}
if ($collectGpuUsage) {
    $detRows += '<tr><td>GPU 占用 平均 / 最高</td><td>' + (Fmt $summary.gpu_util_avg_pct '0.0') + ' / ' + (Fmt $summary.gpu_util_max_pct '0.0') + ' %</td></tr>'
}
if ($collectVram) {
    $detRows += '<tr><td>显存 平均 / 最高（本程序）</td><td>' + (Fmt $summary.vram_avg_mb '0') + ' / ' + (Fmt $summary.vram_max_mb '0') + ' MB</td></tr>'
}
if ($collectRam) {
    $detRows += '<tr><td>内存 平均 / 最高（本程序）</td><td>' + (Fmt $summary.ram_avg_mb '0') + ' / ' + (Fmt $summary.ram_max_mb '0') + ' MB</td></tr>'
}
if ($collectRes -and $summary.resolution) {
    $detRows += '<tr><td>分辨率 / 窗口模式</td><td>' + ($summary.resolution -replace 'x', '×') + ' / ' + $summary.window_mode + '</td></tr>'
    if ($summary.monitor) { $detRows += '<tr><td>显示器分辨率</td><td>' + ($summary.monitor -replace 'x', '×') + '</td></tr>' }
}
if ($summary.present_mode) { $detRows += '<tr><td>呈现模式</td><td>' + $summary.present_mode + '</td></tr>' }
$detRows += '<tr><td>采集完整度</td><td>有效 ' + $summary.captured_seconds + 's / 采集 ' + $summary.wall_seconds + 's</td></tr>'

# 页头 / 页脚
$apiText2 = if ($apiName -eq 'DXGI') { 'DirectX' } elseif ($apiName -eq 'Vulkan') { 'Vulkan' } elseif ($apiName -and $apiName -ne 'Unknown') { $apiName } else { '' }
$metaParts = @($exeBase, ('PID ' + $GamePid))
if ($collectRes -and $summary.resolution) { $metaParts += ('<b>' + ($summary.resolution -replace 'x', '×') + ' / ' + $summary.window_mode + '</b>') }
if ($collectFeatures -and $apiText2) { $metaParts += ('后端 <b>' + $apiText2 + '</b>') }
$metaHtml = $metaParts -join ' · '

$fgPctText = if ($null -ne $summary.foreground_pct) { $summary.foreground_pct.ToString() + '%' } else { 'NA' }

$skipNames = @()
if (-not $collectLatency) { $skipNames += '上屏延迟' }
if (-not $collectGpuTemp)  { $skipNames += 'GPU 温度' }
if (-not $collectGpuUsage) { $skipNames += 'GPU 占用' }
if (-not $collectVram)     { $skipNames += '显存' }
if (-not $collectRam)      { $skipNames += '内存' }
if (-not $collectFeatures) { $skipNames += '图显特性' }
if (-not $collectRes) { $skipNames += '分辨率' }
if (-not $collectChart) { $skipNames += '帧时间曲线' }
$skipNote = ''
if ($skipNames.Count -gt 0) { $skipNote = '本次未采集：' + ($skipNames -join '、') + '。<br>' }

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

<div class="grid">
$cards</div>

<h2>评估</h2>
$verdictItems
$secChart$secFeatures<h2>详细数据</h2>
<table class="det">
$detRows
</table>

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
