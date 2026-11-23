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
# 采样脚本会把一轮拆成 IntervalMs/250 个子步推送（这里 4 次/秒），所以缓冲点数要 ×4
# 才能保持「约 2 分钟」的历史窗口；界面按 caps.ringSize 自适应，不用改前端常量。
$script:MetricsPushPerSec = 4
$script:MetricsRingSize = 120 * $script:MetricsPushPerSec
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
$script:MetricsWorkerRestartAt = $null
$script:MetricsFpsCsv = ''
$script:MetricsFpsErrLast = ''
$script:MetricsFpsErrAt = $null

# ---------- 一轮采样（runspace 里执行；单引号 here-string，禁止变量展开） ----------
$script:MetricsSampleScript = @'
param($SmiPath, $Queue, $IntervalMs, $Ctl, $PmExe, $FpsCsv, $FpsPid, $FpsFixed, $RtssReaderCode, $VendorReaderCode, $ThrottleReaderCode)

# 批次 D：在本 runspace 内定义外部共享内存读取器（源码由宿主以参数传入，避免跨作用域依赖）。
# 目前只有 RTSS 读取器；新增读取器时在此注入其源码，并在下面的分派处按 Ctl.shmReader 加分支。
if ($RtssReaderCode) { . ([scriptblock]::Create($RtssReaderCode)) }
# 平台规则 / 厂商温度 / 事件日志降频：三个模块都无 UI 与日志依赖，可直接在本 runspace 定义。
# 顺序不能反：vendor-sensor 依赖 platform-rules 的 Get-PlatformProfile。
if ($VendorReaderCode) { . ([scriptblock]::Create($VendorReaderCode)) }
if ($ThrottleReaderCode) { . ([scriptblock]::Create($ThrottleReaderCode)) }

# ---- 实时 FPS：PresentMon burst（短窗口采集 → 进程退出后解析）----
# 为什么不能「边采边读」：PresentMon 用 --output_file 时是**独占**打开（FileShare.None），
# 跨进程读不到；--output_stdout 走管道是**块缓冲**，几秒内拿不到行。两条路都堵死（见 FPS-证据链.md §5）。
# 所以每轮起一个 2 秒窗口（--timed 2 --terminate_after_timed），等它自己退出、文件锁释放后再整份解析。
# 目标进程 = 当前前台窗口的进程（排除本程序），退回「采集页上次选中的进程」$FpsPid。
if (-not ('PerfFg' -as [type])) {
    Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class PerfFg{[DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();[DllImport("user32.dll")]public static extern int GetWindowThreadProcessId(IntPtr h,out int pid);public static int Pid(){int p=0;GetWindowThreadProcessId(GetForegroundWindow(),out p);return p;}}' -ErrorAction SilentlyContinue
}
$hostPid = $PID
$isAdm = $false
try { $isAdm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
$fps = @{ proc = $null; ok = $false; pid = 0; target = ''; err = ''; cand = -1; hits = 0;
          starve = 0; session = ''; started = $null; value = $null; frames = 0;
          emptyBursts = 0; burstSec = 1; timeout = 12; backoff = 0; lastDur = 0; p95 = $null; lastOkAt = $null;
          low1 = $null; dl = $null }
# 窗口滑动记录必须是 List：数组是固定长度，RemoveAt 会抛「集合的大小是固定的」
$fps.win = New-Object System.Collections.Generic.List[object]
# 1% Low 的跨段窗口：累计最近约 6 秒的帧时间（200 FPS 下约 1200 帧），样本够了才有统计意义
$fps.ftWin = New-Object System.Collections.Generic.List[double]
$fps.ftWinSec = 0.0
$fps.ftWinMaxSec = 6.0
# 流式采样的水位与窗口：readPos 是已读到的字节位置，partial 是没写完的尾巴
$fps.readPos = 0
$fps.partial = ''
$fps.headerRead = $false
$fps.colCount = 0
$fps.iFt = -1
$fps.iDl = -1
# FPS 用最近 1 秒的帧；RLAT 只留最近约 600 帧
$fps.secWin = New-Object System.Collections.Generic.List[double]
$fps.secWinSec = 0.0
$fps.dlWin = New-Object System.Collections.Generic.List[double]
# burst = 短窗口（默认）：实测 PresentMon 以独占方式打开 CSV，
#         写入期间别的进程读不到内容（只能看到文件大小在涨），
#         所以「常驻 + 增量读」这条路走不通，默认回到短窗口。
# stream = 保留代码但不默认启用（见 Update-FpsStream）。
$fps.mode = 'burst'
$fps.streamFail = 0
$fps.errFile = $null
$fps.openFail = 0

function Resolve-FpsTarget {
    param([int]$Fallback)
    # 用户在「实时监控」里指定了目标进程 → 固定用它（进程还活着时），不再跟随前台
    if ($FpsFixed -and $FpsPid -gt 0) {
        try { [void](Get-Process -Id $FpsPid -ErrorAction Stop); return $FpsPid } catch { }
    }
    $fg = 0
    try { if ('PerfFg' -as [type]) { $fg = [PerfFg]::Pid() } } catch { $fg = 0 }
    if ($fg -gt 0 -and $fg -ne $hostPid) { return $fg }
    if ($Fallback -gt 0) {
        try { [void](Get-Process -Id $Fallback -ErrorAction Stop); return $Fallback } catch { }
    }
    return 0
}

function Stop-FpsStream {
    if ($fps.proc) { try { if (-not $fps.proc.HasExited) { Stop-Process -Id $fps.proc.Id -Force } } catch { } }
    # 杀掉 presentmon 不会自动移除它的 ETW 会话，顺手 stop 掉自己那一个（唯一名，不会误伤别人）
    if ($fps.session) {
        try { & (Join-Path $env:SystemRoot 'System32\logman.exe') stop $fps.session -ets 2>&1 | Out-Null } catch { }
        $fps.session = ''
    }
    if ($FpsCsv -and (Test-Path -LiteralPath $FpsCsv)) { Remove-Item -LiteralPath $FpsCsv -Force -ErrorAction SilentlyContinue }
    $fps.proc = $null
    $fps.ok = $false
    $fps.pid = 0
    $fps.target = ''
    # 换目标 / 重开流时，旧目标的帧不能掺进新窗口
    $fps.readPos = 0
    $fps.partial = ''
    $fps.headerRead = $false
}

# 清空帧时间窗口：只在「换目标」时调用。流/burst 自己的重启不能清，
# 否则 6 秒 1%L 窗口永远攒不满，1%L 就会时有时无。
function Reset-FpsWindows {
    if ($fps.secWin) { $fps.secWin.Clear(); $fps.secWinSec = 0.0 }
    if ($fps.ftWin) { $fps.ftWin.Clear(); $fps.ftWinSec = 0.0 }
    if ($fps.dlWin) { $fps.dlWin.Clear() }
    $fps.value = $null
    $fps.low1 = $null
    $fps.dl = $null
}

# 开采集前清场：上一轮 PresentMon 被强杀会留下**卡死的 ETW 会话**，它占着 DxgKrnl 之后
# 新会话一帧也收不到（实测：清掉 PerfCaptureLive_*/PresentMon 后，同一目标 8 秒立刻出 1661 帧）。
function Clear-FpsSessions {
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

# 解析一个已经退出的 burst CSV：返回 帧数 / 窗口时长 / FPS / 1% Low / P95
# 1% Low（单位 FPS）：把最近约 6 秒的帧时间合并后，取最慢 1% 的平均帧时间再取倒数。
# 单段只有 1 秒：200 FPS 时 60–200 帧，段内 1% 只有 1–2 帧，算出来等于「这一秒最慢的帧」，
# 每秒乱跳且系统性偏高 —— 那不能叫 1% Low。
function Get-FpsLow1 {
    param($FtList)
    if (-not $FtList -or $FtList.Count -lt 20) { return $null }
    $arr = $FtList.ToArray()
    [System.Array]::Sort([double[]]$arr)
    $total = $arr.Length
    $n = [int][math]::Ceiling($total * 0.01)
    if ($n -lt 1) { $n = 1 }
    $sum = 0.0
    for ($i = $total - $n; $i -lt $total; $i++) { $sum += $arr[$i] }
    $slow = $sum / $n
    if ($slow -le 0) { return $null }
    return 1000.0 / $slow
}

# 1%L 的三种状态（2.1.11）：null 不等于「这台机器没有」。
#   ok      = 已经算出来了
#   warming = 收到帧了，但样本还不足（窗口未满 / 帧数 < 20），再等几秒就有
#   idle    = 一个帧都没收到（没选目标 / 游戏不出帧）
# 不区分的话，浮窗只能一律显示 N/A，把「再等一下」说成「拿不到」。
function Get-FpsLow1State {
    param($Fps)
    if ($null -ne $Fps.low1) { return 'ok' }
    if ($Fps.ftWin -and $Fps.ftWin.Count -gt 0) { return 'warming' }
    return 'idle'
}

function Get-BurstFrames {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $lines = @()
    try { $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop) } catch { return $null }
    if ($lines.Count -lt 2) { return $null }
    $hdr = $lines[0] -split ','
    $colCount = $hdr.Count
    $iFt = [array]::IndexOf($hdr, 'FrameTime')
    $iOn = [array]::IndexOf($hdr, 'CPUStartTime')
    if ($iFt -lt 0) { return $null }
    $n = 0
    $sum = 0.0
    $first = $null
    $last = $null
    $lastFt = 0.0
    $list = New-Object System.Collections.Generic.List[double]
    $dlSum = 0.0; $dlN = 0
    $iDl = [array]::IndexOf($hdr, 'DisplayLatency')
    for ($ln = 1; $ln -lt $lines.Count; $ln++) {
        $f = $lines[$ln] -split ','
        if ($f.Count -ne $colCount) { continue }
        $ft = 0.0
        if (-not [double]::TryParse($f[$iFt], [ref]$ft)) { continue }
        if ($ft -le 0) { continue }
        $n++
        $sum += $ft
        $list.Add($ft)
        if ($iOn -ge 0) {
            $o = 0.0
            if ([double]::TryParse($f[$iOn], [ref]$o)) {
                if ($null -eq $first) { $first = $o }
                $last = $o
                $lastFt = $ft
            }
        }
        if ($iDl -ge 0) {
            $dv = 0.0
            if ([double]::TryParse($f[$iDl], [ref]$dv) -and $dv -ge 0) { $dlSum += $dv; $dlN++ }
        }
    }
    if ($n -le 0) { return $null }
    $avgFt = $sum / $n
    # 渲染延迟（RLAT）= 这次 present 到真正上屏的平均毫秒数（PresentMon 的 DisplayLatency）
    $dl = $null
    if ($dlN -gt 0) { $dl = [math]::Round($dlSum / $dlN, 2) }
    $dur = 0.0
    if ($null -ne $first -and $null -ne $last -and $last -gt $first) {
        # 首帧起点 → 末帧起点 + **末帧自己的**时长 = 这 N 帧真正覆盖的时间
        # （用平均帧时间会算错：末帧恰好是长帧时会把窗口算短、FPS 算高）
        $dur = ($last - $first) / 1000.0 + $lastFt / 1000.0
    }
    if ($dur -le 0.05) { $dur = $sum / 1000.0 }
    $val = $n / $dur
    if ($val -le 0 -or $val -gt 2000) { $val = 1000.0 / $avgFt }
    $sorted = @($list | Sort-Object -Descending)
    $n1 = [math]::Max(1, [int][math]::Ceiling($sorted.Count * 0.01))
    $slow = ($sorted | Select-Object -First $n1 | Measure-Object -Average).Average
    # low1 必须是 **FPS**。以前这里直接把平均帧时间（ms）当 low1 返回，前端按 FPS 显示，
    # 等于把「20 ms」读成「20 FPS」——从 2.0.18 起就是错的，这也是「体感不准」的主因。
    $low1Fps = $null
    if ($slow -gt 0) { $low1Fps = 1000.0 / $slow }
    $p95 = $null
    $idx95 = [int][math]::Ceiling($sorted.Count * 0.05) - 1
    if ($idx95 -lt 0) { $idx95 = 0 }
    if ($idx95 -lt $sorted.Count) { $p95 = $sorted[$idx95] }
    return @{ frames = $n; dur = $dur; fps = $val; low1 = $low1Fps; p95 = $p95; dl = $dl; avgft = $avgFt; fts = $list }
}

# ---------- 帧时间窗口（流式与回退两条路共用） ----------
# 追加一批帧时间（毫秒），返回真正收下的帧数
function Add-FpsFrames {
    param($Fts)
    if (-not $Fts) { return 0 }
    $n = 0
    foreach ($fv in $Fts) {
        $d = [double]$fv
        if ($d -le 0 -or $d -gt 5000) { continue }
        [void]$fps.ftWin.Add($d)
        [void]$fps.secWin.Add($d)
        $fps.ftWinSec += ($d / 1000.0)
        $fps.secWinSec += ($d / 1000.0)
        $n++
    }
    return $n
}

# 裁剪窗口并重算 FPS / 1%L / RLAT（两个窗口的时长都以「帧时间之和」为准，不看墙钟）
function Update-FpsDerived {
    while ($fps.secWin.Count -gt 1 -and $fps.secWinSec -gt 1.0) {
        $fps.secWinSec -= ([double]$fps.secWin[0] / 1000.0)
        $fps.secWin.RemoveAt(0)
    }
    while ($fps.ftWin.Count -gt 1 -and $fps.ftWinSec -gt $fps.ftWinMaxSec) {
        $fps.ftWinSec -= ([double]$fps.ftWin[0] / 1000.0)
        $fps.ftWin.RemoveAt(0)
    }
    while ($fps.dlWin.Count -gt 600) { $fps.dlWin.RemoveAt(0) }
    if ($fps.secWinSec -gt 0 -and $fps.secWin.Count -ge 2) {
        $fps.value = [math]::Round($fps.secWin.Count / $fps.secWinSec, 1)
    }
    $fps.low1 = Get-FpsLow1 $fps.ftWin
    if ($fps.dlWin.Count -gt 0) {
        $dlS = 0.0
        foreach ($d in $fps.dlWin) { $dlS += $d }
        $fps.dl = [math]::Round($dlS / $fps.dlWin.Count, 2)
    }
    if ($null -ne $fps.value) {
        $fps.lastOkAt = Get-Date
        $fps.starve = 0
    }
}

# ---------- 流式 FPS：常驻 presentmon + 增量读 CSV ----------
# 旧做法每秒起一个 presentmon、--timed 让它自己退出、再整份解析 CSV：
# 每次都要重建 ETW 会话，起动开销 0.3–0.8 s，读数延迟 1.5–2.5 s。
# NVIDIA app 快，是因为它常驻一个 ETW 消费者持续收事件。这里改成同样思路：
# presentmon 一直跑，我们每 tick 只读文件**新增的那一段**。
function Start-FpsStream {
    param([int]$TargetPid)
    Stop-FpsStream
    if (-not $PmExe -or -not $FpsCsv -or $TargetPid -le 0) { return }
    if (-not (Test-Path -LiteralPath $PmExe)) { return }
    try {
        if (Test-Path -LiteralPath $FpsCsv) { Remove-Item -LiteralPath $FpsCsv -Force -ErrorAction SilentlyContinue }
        $fps.session = 'PerfCaptureLive_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        # 不传 --timed：一直采到我们主动停。
        # 也不传 --terminate_on_proc_exit：实测它会一启动就退出（目标进程还没在 ETW 里
        # 出现就被判成「已退出」），结果连 CSV 都不创建 —— 实时 FPS 因此一直是「—」。
        # 目标退出改由采样循环自己检测（Get-Process 失败 → Stop-FpsStream）。
        $pmArgs = @('--process_id', "$TargetPid", '--output_file', $FpsCsv,
                    '--v2_metrics', '--no_console_stats',
                    '--session_name', $fps.session, '--stop_existing_session')
        # 把 presentmon 的 stderr 收下来：以后它再异常退出，日志里能看到真实原因
        $fps.errFile = Join-Path $env:TEMP 'PerfCapture\presentmon-stderr.txt'
        try { [IO.File]::WriteAllText($fps.errFile, '') } catch { $fps.errFile = $null }
        if ($fps.errFile) {
            $fps.proc = Start-Process -FilePath $PmExe -ArgumentList $pmArgs -PassThru -WindowStyle Hidden -RedirectStandardError $fps.errFile
        } else {
            $fps.proc = Start-Process -FilePath $PmExe -ArgumentList $pmArgs -PassThru -WindowStyle Hidden
        }
        $fps.started = Get-Date
        $fps.ok = $true
        $fps.pid = $TargetPid
        $fps.readPos = 0
        $fps.partial = ''
        $fps.headerRead = $false
        $fps.colCount = 0
        $fps.iFt = -1
        $fps.iDl = -1
        # 不在这里清窗口：burst 每次重启 presentmon 都要重来一遍，
        # 清掉就等于 6 秒 1%L 窗口永远攒不满（这正是 1%L 时有时无的原因）。
        # 换目标时才清，见 Reset-FpsWindows 的调用点。
        try { $fps.target = (Get-Process -Id $TargetPid -ErrorAction Stop).ProcessName } catch { $fps.target = '' }
    } catch {
        $fps.ok = $false
        $fps.err = 'start: ' + $_.Exception.Message
        $fps.proc = $null
        $fps.pid = 0
        $fps.backoff = 10
    }
}

# 停摆保护：超过 N 秒没有新帧 → 读数值视为失效（不许把十分钟前的数字当现状）
function Test-FpsStale {
    param($State, [int]$LimitSec = 8)
    if (-not $State -or -not $State.lastOkAt) { return $false }
    return (((Get-Date) - $State.lastOkAt).TotalSeconds -gt $LimitSec)
}

# 把新增文本切成完整行；最后一段可能只写了一半，留到下次拼接
function Split-FpsChunk {
    param([string]$Text, [string]$Pending)
    $all = [string]$Pending + [string]$Text
    if (-not $all) { return @{ rows = @(); rest = '' } }
    $lastNl = $all.LastIndexOf("`n")
    if ($lastNl -lt 0) { return @{ rows = @(); rest = $all } }
    $head = $all.Substring(0, $lastNl + 1)
    $rest = $all.Substring($lastNl + 1)
    $rows = @($head -split "`r?`n" | Where-Object { $_ -and $_.Trim() })
    return @{ rows = $rows; rest = $rest }
}

# 每 tick 调用：读 CSV 新增部分 → 追加帧时间 → 重算 FPS / 1%L / RLAT
function Update-FpsStream {
    if (-not $fps.proc) { return }
    $exited = $false
    try { $fps.proc.Refresh(); $exited = $fps.proc.HasExited } catch { }

    # 先把已落盘的部分读完 —— 即使进程刚退出也要读，别丢掉最后一截
    $added = 0
    try {
        if (Test-Path -LiteralPath $FpsCsv) {
            $len = (New-Object System.IO.FileInfo($FpsCsv)).Length
            if ($len -lt $fps.readPos) { $fps.readPos = 0; $fps.partial = ''; $fps.headerRead = $false }
            if ($len -gt $fps.readPos) {
                $fs = [IO.File]::Open($FpsCsv, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try {
                    [void]$fs.Seek($fps.readPos, [IO.SeekOrigin]::Begin)
                    $want = [int][Math]::Min(($len - $fps.readPos), 1048576)
                    $buf = New-Object byte[] $want
                    $got = $fs.Read($buf, 0, $want)
                    if ($got -gt 0) {
                        $fps.readPos += $got
                        $sp = Split-FpsChunk -Text ([Text.Encoding]::UTF8.GetString($buf, 0, $got)) -Pending $fps.partial
                        $fps.partial = $sp.rest
                        foreach ($row in $sp.rows) {
                            $f = $row -split ','
                            if (-not $fps.headerRead) {
                                $fps.iFt = [array]::IndexOf($f, 'FrameTime')
                                $fps.iDl = [array]::IndexOf($f, 'DisplayLatency')
                                $fps.colCount = $f.Count
                                $fps.headerRead = $true
                                continue
                            }
                            if ($fps.colCount -le 0 -or $f.Count -ne $fps.colCount -or $fps.iFt -lt 0) { continue }
                            $ft = 0.0
                            if (-not [double]::TryParse($f[$fps.iFt], [ref]$ft)) { continue }
                            if ($ft -le 0 -or $ft -gt 5000) { continue }
                            $added++
                            [void]$fps.ftWin.Add($ft)
                            [void]$fps.secWin.Add($ft)
                            $fps.ftWinSec += ($ft / 1000.0)
                            $fps.secWinSec += ($ft / 1000.0)
                            if ($fps.iDl -ge 0) {
                                $dv = 0.0
                                if ([double]::TryParse($f[$fps.iDl], [ref]$dv) -and $dv -ge 0) { [void]$fps.dlWin.Add($dv) }
                            }
                        }
                    }
                } finally { $fs.Dispose() }
            }
        }
    } catch { }

    # 裁剪 + 重算统一走公共函数（与回退路径同一套口径）
    Update-FpsDerived
    if ($added -gt 0) {
        $fps.frames += $added
        $fps.err = ''
        $fps.backoff = 0
        $fps.openFail = 0
        $fps.lastDur = [math]::Round($fps.secWinSec, 2)
    } elseif (-not $exited) {
        # 进程还在、却一个字节都读不到：多半是 CSV 被独占锁住（旧注释里记过这种情况）。
        # 连续 5 次就判定为「读不了」，切回短窗口 burst，别让 FPS 变成永远的「—」。
        $fps.openFail++
        if ($fps.openFail -ge 5) {
            $fps.err = '采集流不可读（CSV 可能被独占），已切回短窗口模式'
            $fps.mode = 'burst'
            $fps.openFail = 0
            Stop-FpsStream
            return
        }
    }

    if ($exited) {
        $code = $null
        try { $code = $fps.proc.ExitCode } catch { }
        $fps.proc = $null
        $fps.ok = $false
        $fps.session = ''
        # 把 presentmon 自己的 stderr 带出来，否则只剩「没有新帧」这种没信息量的话
        $pmMsg = ''
        try {
            if ($fps.errFile -and (Test-Path -LiteralPath $fps.errFile)) {
                $txt = (Get-Content -LiteralPath $fps.errFile -Raw -ErrorAction SilentlyContinue)
                if ($txt) { $pmMsg = (($txt -replace '\s+', ' ').Trim()) }
                if ($pmMsg.Length -gt 180) { $pmMsg = $pmMsg.Substring(0, 180) }
            }
        } catch { }
        if ($code -eq 6) {
            $fps.err = 'PresentMon 无法创建 ETW 会话（退出码 6）：需要以管理员身份运行 PerfCapture'
            $fps.backoff = 15
        } elseif ($null -ne $code -and $code -ne 0) {
            $fps.err = ('presentmon 退出码 ' + $code + '（未提权或 ETW 会话被占用）' + $(if ($pmMsg) { '：' + $pmMsg } else { '' }))
            $fps.backoff = 10
        } elseif ($added -eq 0) {
            # 启动了却一帧都没有：累计；连续 3 次就判定流式不可用，切回短窗口模式，
            # 否则会陷进「每轮重启 → 立刻退出」的死循环（FPS 永远不显示）。
            $fps.starve++
            $fps.streamFail++
            if ($fps.streamFail -ge 3) {
                $fps.err = '流式采样连续 3 次拿不到数据，已切回短窗口模式' + $(if ($pmMsg) { '：' + $pmMsg } else { '' })
                $fps.mode = 'burst'
                $fps.streamFail = 0
                $fps.backoff = 0
            } else {
                $fps.err = ('采集流启动后没有数据（第 {0} 次，提权={1}）' -f $fps.streamFail, $isAdm) + $(if ($pmMsg) { '：' + $pmMsg } else { '' })
                $fps.backoff = 2
            }
        } else {
            $fps.backoff = 0
            $fps.streamFail = 0
        }
        return
    }

    # 文件长到 32 MB 就重建一次（200 FPS 约 9 分钟），避免无限增长
    if ($fps.readPos -gt 33554432) { Start-FpsStream -TargetPid $fps.pid }
}

# ---------- 回退路径：短窗口 burst（CSV 被独占时的保险） ----------
# 与流式路径共用 Add-FpsFrames / Update-FpsDerived，口径完全一致，
# 区别只在于「每轮起一个 --timed 窗口、等它退出再整份解析」。
function Start-FpsBurstWindow {
    param([int]$TargetPid)
    Stop-FpsStream
    if (-not $PmExe -or -not $FpsCsv -or $TargetPid -le 0) { return }
    if (-not (Test-Path -LiteralPath $PmExe)) { return }
    try {
        if (Test-Path -LiteralPath $FpsCsv) { Remove-Item -LiteralPath $FpsCsv -Force -ErrorAction SilentlyContinue }
        $fps.session = 'PerfCaptureLive_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $pmArgs = @('--process_id', "$TargetPid", '--output_file', $FpsCsv,
                    # 窗口必须用整数秒：实测 --timed 0.5 会让 PresentMon 一帧都不采（文件 0 字节），
                    # 只能写 '1'。想更快出数得换采集通道，不能靠缩窗口。
                    '--timed', '1', '--terminate_after_timed',
                    '--v2_metrics', '--no_console_stats',
                    '--session_name', $fps.session, '--stop_existing_session')
        $fps.proc = Start-Process -FilePath $PmExe -ArgumentList $pmArgs -PassThru -WindowStyle Hidden
        # 让 presentmon 降到 BelowNormal：它只做 ETW 解析，不该和游戏抢 CPU 时间片
        try { $fps.proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }
        $fps.started = Get-Date
        $fps.ok = $true
        $fps.pid = $TargetPid
        try { $fps.target = (Get-Process -Id $TargetPid -ErrorAction Stop).ProcessName } catch { $fps.target = '' }
    } catch {
        $fps.ok = $false
        $fps.err = 'start: ' + $_.Exception.Message
        $fps.proc = $null
        $fps.pid = 0
        $fps.backoff = 10
    }
}

function Complete-FpsBurstWindow {
    if (-not $fps.proc) { return }
    $exited = $false
    try { $fps.proc.Refresh(); $exited = $fps.proc.HasExited } catch { }
    if (-not $exited) { return }
    $code = $null
    try { $code = $fps.proc.ExitCode } catch { }
    $r = Get-BurstFrames -Path $FpsCsv
    $fps.proc = $null
    $fps.ok = $false
    $fps.session = ''
    if ($r -and $r.fts -and $r.fts.Count -gt 0) {
        [void](Add-FpsFrames $r.fts)
        if ($r.dl -and $fps.dlWin) {
            # burst 只有平均值，按值补进 RLAT 窗口（口径仍是「最近若干帧的平均」）
            for ($i = 0; $i -lt [Math]::Min($r.frames, 60); $i++) { [void]$fps.dlWin.Add([double]$r.dl) }
        }
        Update-FpsDerived
        $fps.frames += $r.frames
        $fps.err = ''
        $fps.backoff = 0
        $fps.lastDur = [math]::Round($r.dur, 2)
    } else {
        $fps.starve++
        if ($code -eq 6) {
            $fps.err = 'PresentMon 无法创建 ETW 会话（退出码 6）：需要以管理员身份运行 PerfCapture'
            $fps.backoff = 15
        } elseif ($null -ne $code -and $code -ne 0) {
            $fps.err = ('presentmon 退出码 ' + $code + '（未提权或 ETW 会话被占用）')
            $fps.backoff = 10
        } else {
            $fps.err = ('目标 {0}(pid {1}) 这个窗口没有帧（提权={2}）' -f $fps.target, $fps.pid, $isAdm)
            $fps.backoff = 3
        }
        # 失败时清一次残留 ETW 会话（15 秒节流）。presentmon 被强杀会留下卡死的会话，
        # 它占着 DxgKrnl 会让后续采集一帧都收不到（实测：丢 9 万条事件、0 帧）。
        # logman query 本身有开销，所以只在失败时清、并且限频。
        try {
            if (((Get-Date) - $script:lastSessionClean).TotalSeconds -ge 15) {
                $script:lastSessionClean = Get-Date
                Clear-FpsSessions
            }
        } catch { }
    }
}

# 采样循环启动前先清一次残留 ETW 会话（卡死的会话会让后面所有窗口收不到帧）
Clear-FpsSessions
# CPU 封装功耗（PDH Energy Meter / rapl_package0_pkg，单位 mW）：与报告口径一致；平台没有就不给值
$cpuPwrCounter = $null
try {
    $cpuPwrCounter = New-Object System.Diagnostics.PerformanceCounter('Energy Meter', 'power', 'rapl_package0_pkg')
    [void]$cpuPwrCounter.NextValue()
    Start-Sleep -Milliseconds 300
    [void]$cpuPwrCounter.NextValue()
} catch { $cpuPwrCounter = $null }
# GPU 采样状态：NVML 优先（<1 ms），不可用时回退 nvidia-smi；两者都按 2 轮一次降频
# NVML 的类型在循环内才编译（与 PcMetrics 同一段），所以这里只置位，真正 Start 放在
# GPU 采样段前做一次惰性初始化 —— 否则循环外判断时类型还不存在，永远回退 nvidia-smi。
$gpuUseNvml = $false
$gpuInit = $false
$gpuTick = 0
$gpuCache = @{}
# 上次清理残留 ETW 会话的时间（失败时才清，且至少间隔 15 秒，避免 logman 本身变成开销）
$script:lastSessionClean = Get-Date
while ($true) {
    if ($Ctl -and $Ctl.stop) { break }
    try {
    # ---- 批次 D：数据源仲裁 ----
    # 当前 FPS 源是外部共享内存扩展时，读 RTSS 出数，且绝不启动 PresentMon（ETW 会话全局互斥）。
    # 读失败分两类：待机（暂无活跃游戏）只报 N/A；真故障才请求宿主回退，不把「没开游戏」当成坏扩展。
    $fpsSrc = if ($Ctl) { [string]$Ctl.fpsSource } else { 'presentmon' }
    if ($fpsSrc -and $fpsSrc -ne 'presentmon') {
        if ($fps.proc) { Stop-FpsStream }   # 切源瞬间：停掉上一源残留的 PresentMon
        $snap = $null
        # 读取器按 Ctl.shmReader 分派：目前只有 rtss；新增读取器时在此加分支。
        $readerKind = if ($Ctl -and $Ctl.shmReader) { [string]$Ctl.shmReader } else { 'rtss' }
        if ($readerKind -eq 'rtss' -and (Get-Command Get-RtssFrameSnapshot -ErrorAction SilentlyContinue)) {
            $snap = Get-RtssFrameSnapshot
        }
        if ($snap -and $snap.ok) {
            $fps.value = $snap.fps
            $fps.low1 = $snap.fpsLow1
            $fps.target = $snap.processName
            $fps.err = ''
            $fps.lastOkAt = Get-Date
            # 高频数据源：帧时间窗口同步一份，供 1% Low / P95 口径与上报一致
            $fps.ftWin.Clear()
            [void]$fps.ftWin.Add([double]$snap.frameTimeUs)
        } else {
            $fps.value = $null
            $fps.low1 = $null
            $why = if ($snap -and $snap.reason) { $snap.reason } else { 'readerMissing' }
            # 故障口径由宿主（80-Extensions 的 ShmBrokenReasons）经 Ctl 注入，避免两处各维护一份列表。
            # 未注入时保守按故障处理：宁可回退，也不让界面停在假的「已接管」。
            $brokenReasons = if ($Ctl -and $Ctl.brokenReasons) { @($Ctl.brokenReasons) } else { @($why) }
            if ($brokenReasons -contains $why) {
                $fps.err = ('扩展数据源 {0} 读取失败：{1}' -f $fpsSrc, $why)
                if ($Ctl) { $Ctl.fpsRequestFallback = $true }
            } else {
                # 待机：RTSS 正常、只是当前没有游戏在采集。显示 N/A，不报错、不回退、不关扩展。
                $fps.err = ''
            }
        }
        # 数据源标记随 sample 上报，报告/界面据此标注来源，不假装亚秒级
        $fps.sourceTag = $fpsSrc
    } else {
    # 目标选择：优先跟随前台，但**只在当前目标没在出帧时才换**（alt-tab 到浏览器就换目标会让帧数永远攒不起来）
    $cand = Resolve-FpsTarget -Fallback $FpsPid
    if ($cand -ne $fps.cand) { $fps.cand = $cand; $fps.hits = 0 } else { $fps.hits++ }
    $wantPid = $fps.pid
    if ($cand -gt 0) {
        if ($fps.pid -le 0) { $wantPid = $cand }
        elseif ($cand -ne $fps.pid) {
            # 固定目标不设门限：用户在「目标进程」里点名了哪个进程，就立刻切过去。
            # 「等旧目标连续饿死才换」只适用于跟随前台 —— 那时旧目标还在出帧就不该乱切。
            if ($FpsFixed) { Stop-FpsStream; Reset-FpsWindows; $wantPid = $cand }
            elseif ($fps.hits -ge 3 -and $fps.starve -ge 3) { $wantPid = $cand }
        }
    }
    # 目标已经退出：收掉流，别再追它
    if ($wantPid -gt 0) {
        try { [void](Get-Process -Id $wantPid -ErrorAction Stop) } catch { $wantPid = 0; Stop-FpsStream; Reset-FpsWindows }
    }
    # 目标变了（跟随前台切换时常见）：重开流，两个进程的帧绝不能混在一个窗口里
    if ($fps.proc -and $wantPid -gt 0 -and $fps.pid -ne $wantPid) { Stop-FpsStream; Reset-FpsWindows }
    if ($fps.mode -eq 'burst') {
        # 回退路径：等这一轮窗口自己退出，再整份解析（比流式慢，但一定拿得到数据）
        if ($fps.proc) { Complete-FpsBurstWindow }
        elseif ($fps.backoff -gt 0) { $fps.backoff-- }
        elseif ($wantPid -gt 0) { Start-FpsBurstWindow -TargetPid $wantPid }
    } else {
        if (-not $fps.proc -and $wantPid -gt 0) {
            if ($fps.backoff -gt 0) { $fps.backoff-- }
            else { Start-FpsStream -TargetPid $wantPid }
        }
        # 每 tick 只读 CSV 里新增的那一段 —— 不再重起 presentmon
        Update-FpsStream
    }
    $fps.sourceTag = 'presentmon'
    }   # end else (PresentMon 基线)
    } catch {
        # 任何一次异常都不许弄死整个采样线程（1.5.10 就是这么停摆的：FPS 值冻在旧数上）
        $fps.err = 'tick: ' + $_.Exception.Message
        if ($fps.proc) { try { Stop-Process -Id $fps.proc.Id -Force } catch { } }
        $fps.proc = $null
        $fps.backoff = 3
    }
$out = [ordered]@{
    at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    cpu = $null; cpuMhz = $null; cpuMhzMax = $null; cpuTemp = $null; cpuTempSource = ''
    cpuThrottle = $null; cpuThrottleOk = $null; cpuThrottleCount = 0; cpuThrottleReason = ''; cpuThrottleSeconds = $null
    gpu = $null; gpuClock = $null; gpuMemClock = $null; gpuTemp = $null; gpuPower = $null; gpuFan = $null
    vramUsed = $null; vramTotal = $null
    ramUsed = $null; ramTotal = $null
    fps = $null; fpsLow1 = $null; fpsLow1State = 'idle'; rlat = $null; pcl = $null; cpuPower = $null
    fpsTarget = $fps.target
    fpsErr = $fps.err
    fpsSource = if ($fps.sourceTag) { $fps.sourceTag } else { 'presentmon' }
}
function ToNum($v) {
    if ($null -eq $v) { return $null }
    $s = ([string]$v).Trim()
    if (-not $s) { return $null }
    if ($s -match 'N/A|Not Supported|Unknown|^\[.*\]$') { return $null }
    $d = 0.0
    if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$d)) { return $d }
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
# ---- NVML：直接调驱动 DLL 取 GPU 指标（<1 ms，不再每秒 spawn nvidia-smi）----
# nvidia-smi 每次 45–60 ms 的进程启动开销，在 240 FPS 下就是可见的尖峰。
# nvml.dll 由 NVIDIA 驱动装到 System32，零分发成本；任何一项失败都回退 nvidia-smi。
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
        '    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetFanSpeed")] private static extern int Fan(IntPtr h, out uint pct);'
        '    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetMemoryInfo")] private static extern int Mem(IntPtr h, out MemInfo m);'
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
        '    // 返回 gpu%, 图形频率, 显存频率, 温度, 功率W, 风扇%, VRAM已用MB, VRAM总量MB；取不到的项为 -1'
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
        '}'
    ) -join "`n"
    try { Add-Type -TypeDefinition $nvcs -Language CSharp -ErrorAction Stop } catch { }
}

# ---- GPU：优先 NVML（<1 ms），回退 nvidia-smi；两者都每 2 轮采一次 ----
# 降频理由：GPU 温度/功耗/频率在 1 秒尺度上几乎不变，2 秒采一次体感无差异，
# 但把 nvidia-smi 的进程启动开销砍掉一半（若 NVML 不可用时的回退路径）。
# 惰性初始化：这一行必须在 NvGpu 编译之后（编译在循环内的 PcMetrics 段）
if (-not $gpuInit) {
    $gpuInit = $true
    if ('NvGpu' -as [type]) { try { $gpuUseNvml = [NvGpu]::Start() } catch { $gpuUseNvml = $false } }
}
$gpuTick++
if ($gpuTick -eq 1 -or ($gpuTick % 2) -eq 1) {
    $got = $false
    if ($gpuUseNvml) {
        try {
            $snap = [NvGpu]::Sample()
            if ($snap -and $snap.Length -ge 8) {
                if ($snap[0] -ge 0) { $gpuCache['gpu'] = [math]::Round($snap[0], 0) }
                if ($snap[1] -ge 0) { $gpuCache['gpuClock'] = [math]::Round($snap[1], 0) }
                if ($snap[2] -ge 0) { $gpuCache['gpuMemClock'] = [math]::Round($snap[2], 0) }
                if ($snap[3] -ge 0) { $gpuCache['gpuTemp'] = [math]::Round($snap[3], 0) }
                if ($snap[4] -ge 0) { $gpuCache['gpuPower'] = [math]::Round($snap[4], 1) }
                if ($snap[5] -ge 0) { $gpuCache['gpuFan'] = [math]::Round($snap[5], 0) }
                if ($snap[6] -ge 0) { $gpuCache['vramUsed'] = [math]::Round($snap[6], 0) }
                if ($snap[7] -ge 0) { $gpuCache['vramTotal'] = [math]::Round($snap[7], 0) }
                $got = $true
            }
        } catch { $got = $false }
    }
    if (-not $got -and $SmiPath -and (Test-Path -LiteralPath $SmiPath)) {
        try {
            $line = (& $SmiPath --query-gpu=utilization.gpu,clocks.current.graphics,clocks.current.memory,temperature.gpu,power.draw,fan.speed,memory.used,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
            if ($line) {
                $parts = @(([string]$line) -split ',' | ForEach-Object { $_.Trim() })
                if ($parts.Count -ge 8) {
                    $gpuCache['gpu'] = ToNum $parts[0]
                    $gpuCache['gpuClock'] = ToNum $parts[1]
                    $gpuCache['gpuMemClock'] = ToNum $parts[2]
                    $gpuCache['gpuTemp'] = ToNum $parts[3]
                    $gpuCache['gpuPower'] = ToNum $parts[4]
                    $gpuCache['gpuFan'] = ToNum $parts[5]
                    $gpuCache['vramUsed'] = ToNum $parts[6]
                    $gpuCache['vramTotal'] = ToNum $parts[7]
                }
            }
        } catch { }
    }
}
foreach ($gk in 'gpu', 'gpuClock', 'gpuMemClock', 'gpuTemp', 'gpuPower', 'gpuFan', 'vramUsed', 'vramTotal') {
    if ($gpuCache.ContainsKey($gk)) { $out[$gk] = $gpuCache[$gk] }
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

# ---- CPU 温度：厂商固件通道（当前仅联想，只读 WMI；见《数据源与平台覆盖规则.md》§3）----
# 采不到就是 $null，界面显示「—」；不用 0 或推算值顶替。
try {
    if (Get-Command Get-VendorCpuTempSnapshot -ErrorAction SilentlyContinue) {
        $vt = Get-VendorCpuTempSnapshot
        if ($vt -and $vt.ok -and $null -ne $vt.value) {
            $out.cpuTemp = [int]$vt.value
            $out.cpuTempSource = [string]$vt.source
        }
    }
} catch { }
# ---- CPU 降频：Windows 事件日志 Event 37（30 s 缓存，采样每秒调用也不会重复查询）----
try {
    if (Get-Command Get-CpuThrottleState -ErrorAction SilentlyContinue) {
        $th = Get-CpuThrottleState -WindowSeconds 120
        if ($th) {
            $out.cpuThrottleOk = [bool]$th.ok
            $out.cpuThrottle = [bool]$th.limited
            $out.cpuThrottleCount = [int]$th.count
            $out.cpuThrottleSeconds = $th.maxSeconds
            $out.cpuThrottleReason = [string]$th.reason
        }
    }
} catch { }

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

# ---- 实时 FPS：Update-FpsStream 已算好（FPS 用最近 1 秒滑动窗口，1%L 用最近 ~6 秒）----
# 两次推送之间沿用上一次的值；超过 8 秒没有新帧才清空（见下方 Test-FpsStale）。
if ($null -ne $fps.value) { $out.fps = $fps.value }
if ($cpuPwrCounter) {
    try {
        $cw = [double]$cpuPwrCounter.NextValue() / 1000.0
        if ($cw -gt 0 -and $cw -lt 2000) { $out.cpuPower = [math]::Round($cw, 1) }
    } catch { $cpuPwrCounter = $null }
}
if ($null -ne $fps.low1) { $out.fpsLow1 = [math]::Round([double]$fps.low1, 2) }
$out.fpsLow1State = Get-FpsLow1State $fps
if ($null -ne $fps.dl) { $out.rlat = [math]::Round([double]$fps.dl, 2) }
# 平均 PC 延迟（PCL）= 平均帧时间 + 渲染延迟；两个都在才有值，绝不估算
if ($null -ne $fps.dl -and $null -ne $out.fps -and [double]$out.fps -gt 0) {
    $out.pcl = [math]::Round((1000.0 / [double]$out.fps) + [double]$fps.dl, 2)
}
# 停摆保护：超过 8 秒没有一次成功窗口，就不许再显示旧值（否则用户看到的是十分钟前的数字）
    if (Test-FpsStale $fps) {
        if ($null -ne $fps.value) {
            $fps.value = $null; $fps.low1 = $null; $fps.dl = $null
            $fps.secWin.Clear(); $fps.secWinSec = 0.0
            $fps.ftWin.Clear(); $fps.ftWinSec = 0.0
            $fps.dlWin.Clear()
        }
        if (-not $fps.err) { $fps.err = '流式采样停摆：超过 8 秒没有新帧' }
    }
# 失败现场：只在「出过问题」时带上，宿主负责去重记日志（同一个错误不会每秒刷一条）
if ($fps.err) {
    $csvInfo = if (Test-Path -LiteralPath $FpsCsv) { (Get-Item -LiteralPath $FpsCsv).Length } else { 'no-file' }
    $out.fpsErr = ('目标 {0}(pid {1})：{2}（csv={3} 字节，提权={4}，窗口 {5} s，累计 {6} 帧）' -f
                   $fps.target, $fps.pid, $fps.err, $csvInfo, $isAdm, $fps.lastDur, $fps.frames)
}
# 推送节奏：把一轮采样拆成若干子步，每步只刷新 FPS 相关字段再入队。
# 宿主 Timer 是 250 ms 拉一次队列，所以入队频率就是界面刷新频率：
# 原来一轮 1 秒只能推一次（叠加 burst 起动开销，读数延迟 1.5–2.5 s）；
# 常驻 presentmon 之后只要把入队拆细，延迟就降到 0.25–0.5 s。
$subSteps = [Math]::Max(1, [int][Math]::Floor($IntervalMs / 250))
$stepMs = [int][Math]::Max(50, [Math]::Floor($IntervalMs / $subSteps))
for ($k = 0; $k -lt $subSteps; $k++) {
    if ($Ctl -and $Ctl.stop) { break }
    if ($k -gt 0) {
        Start-Sleep -Milliseconds $stepMs
        try { Update-FpsStream } catch { }
        $out.at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $out.fps = $fps.value
        $out.fpsLow1 = if ($null -ne $fps.low1) { [math]::Round([double]$fps.low1, 2) } else { $null }
        $out.fpsLow1State = Get-FpsLow1State $fps
        $out.rlat = if ($null -ne $fps.dl) { [math]::Round([double]$fps.dl, 2) } else { $null }
        $out.pcl = if ($null -ne $fps.dl -and $null -ne $out.fps -and [double]$out.fps -gt 0) { [math]::Round((1000.0 / [double]$out.fps) + [double]$fps.dl, 2) } else { $null }
        $out.fpsTarget = $fps.target
        $out.fpsErr = $fps.err
    }
    $Queue.Enqueue([pscustomobject]$out)
}
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
        # CPU 温度：$null=未探测；true=这台机器读到过（厂商固件通道，仅联想）
        cpuTemp = $null
        cpuTempSource = ''
        cpuFan = $false
        diskTemp = $false
        sensorPack = $false
        # 降频：$null=未探测；true=日志可读（是否受限看样本 cpuThrottle）
        cpuThrottle = $null
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
    # 温度：读到过就记住「这台机器有」，偶发读失败只让值为 null，不改能力结论
    if ($null -ne $s.cpuTemp) { $c.cpuTemp = $true }
    if ($s.cpuTempSource) { $c.cpuTempSource = [string]$s.cpuTempSource }
    # 降频：以「日志是否可读」为能力，不以「这次是否受限」为能力
    if ($s.cpuThrottleOk -eq $true) { $c.cpuThrottle = $true }
    $c.ram = ($null -ne $s.ramTotal)
}

# ---------- 采样调度 ----------
# 把宿主已加载的模块源码读出来，随采样 runspace 一起注入（runspace 不共享函数表）。
# 读不到就返回空：采样侧会跳过对应能力，绝不让整个监控因为一个模块缺失而起不来。
function Get-MetricsModuleSource([string]$Name) {
    try {
        $root = $script:Root
        if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
        $p = Join-Path $root ('src\app\' + $Name)
        if (Test-Path -LiteralPath $p) { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8) }
    } catch { }
    return ''
}

function Start-MetricsWorker {
    # 采样线程只创建一次：C# 里编译的原生类型与 PDH 查询都是**进程级静态状态**，
    # 每轮重建 runspace 会重新编译类型（静态状态归零、PDH 查询泄漏），
    # 表现为「首轮永远没有频率、退出时访问冲突 0xC0000005」。
    # 所以：常驻 runspace 循环采样 → ConcurrentQueue 回传 → 宿主计时器取走。
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
        if (-not $script:MetricsCtl) { $script:MetricsCtl = @{ stop = $false; fpsSource = 'presentmon'; fpsRequestFallback = $false } }
        $script:MetricsCtl.stop = $false
        $script:MetricsCtl.fpsRequestFallback = $false
        # 数据源仲裁：把当前 FPS 源同步进采样 runspace（hashtable 是跨 runspace 共享引用）。
        $src0 = 'presentmon'
        try { if ($script:ActiveFpsSource) { $src0 = $script:ActiveFpsSource } } catch { }
        $script:MetricsCtl.fpsSource = $src0
        # 待机/故障口径只在 80-Extensions 定义一份，这里注入采样 runspace，
        # 免得「没开游戏」被采样侧当成故障、进而把扩展自动关掉。
        try {
            if ($script:ShmBrokenReasons) { $script:MetricsCtl.brokenReasons = @($script:ShmBrokenReasons) }
        } catch { }
        [void]$ps.AddParameter('Ctl', $script:MetricsCtl)
        [void]$ps.AddParameter('PmExe', $script:MetricsPmPath)
        [void]$ps.AddParameter('FpsCsv', $script:MetricsFpsCsv)
        [void]$ps.AddParameter('FpsPid', $script:MetricsFpsPid)
        [void]$ps.AddParameter('FpsFixed', [bool]$script:MetricsFpsFixed)
        # 批次 D：把读取器源码作为参数传入，采样脚本在自身作用域点源定义函数。
        [void]$ps.AddParameter('RtssReaderCode', $script:RtssReaderSource)
        # 平台规则 + 厂商温度（顺序：platform 先于 vendor）；降频单独注入。
        $vendorSrc = ((Get-MetricsModuleSource 'platform-rules.ps1') + "`n" + (Get-MetricsModuleSource 'vendor-sensor.ps1'))
        if ($vendorSrc.Trim()) { [void]$ps.AddParameter('VendorReaderCode', $vendorSrc) }
        $thrSrc = Get-MetricsModuleSource 'cpu-throttle.ps1'
        if ($thrSrc.Trim()) { [void]$ps.AddParameter('ThrottleReaderCode', $thrSrc) }
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
    # 批次 D：采样线程报告扩展数据源读失败 → 自动回退到 presentmon 零注入基线。
    # 用 try 包住 Set-FpsSource（它在 80-Extensions.ps1 里，加载顺序在本文件之后）。
    if ($script:MetricsCtl -and $script:MetricsCtl.fpsRequestFallback) {
        $script:MetricsCtl.fpsRequestFallback = $false
        try {
            $cur = 'presentmon'
            try { if ($script:ActiveFpsSource) { $cur = $script:ActiveFpsSource } } catch { }
            if ($cur -ne 'presentmon' -and (Get-Command Disable-ExtensionCore -ErrorAction SilentlyContinue)) {
                # 完整关闭：断 IPC + 回退源 + 持久化 + 回推 UI，状态如实变为「已安装未启用」
                [void](Disable-ExtensionCore $cur)
            } elseif (Get-Command Set-FpsSource -ErrorAction SilentlyContinue) {
                [void](Set-FpsSource 'presentmon')
            }
            Write-AppLog '扩展数据源读取失败，已自动回退到 PresentMon 基线（功能不退化，来源已如实标注）' 'WARN'
        } catch { Write-AppLog ('数据源回退失败: ' + $_.Exception.Message) 'WARN' }
    }
    # 采样线程死了就报一次，别静默
    # 采样线程死了就**重启**（1.5.10 的教训：原来直接停掉，于是 FPS 永远冻在旧数上）
    if ($script:MetricsWorker -and $script:MetricsWorker.Handle.IsCompleted) {
        $now = Get-Date
        if ($script:MetricsWorkerRestartAt -and ($now - $script:MetricsWorkerRestartAt).TotalSeconds -lt 30) { return }
        $script:MetricsWorkerRestartAt = $now
        Write-AppLog '监控采样线程已退出，正在重启采样线程（FPS 读数先清空，避免显示旧值）' 'WARN'
        Stop-MetricsWorker
        try { Start-MetricsWorker } catch { Write-AppLog ('重启采样线程失败：' + $_.Exception.Message) 'WARN' }
        Send-ToUi @{ type = 'metricsCaps'; caps = $script:MetricsCaps; running = $script:MetricsRunning }
        return
    }
    if (-not $script:MetricsQueue) { return }
    $sample = $null
    while ($script:MetricsQueue.TryDequeue([ref]$sample)) {
        if (-not $sample) { continue }
        [void]$script:MetricsSamples.Add($sample)
        while ($script:MetricsSamples.Count -gt $script:MetricsRingSize) { $script:MetricsSamples.RemoveAt(0) }
        Update-MetricsCapsFromSample $sample
        if ($sample.fpsErr) {
            # 同一个错误只记一次；仍没恢复就每 2 分钟提醒一次（burst 每 2 秒一轮，不这样会刷屏）
            if ($sample.fpsErr -ne $script:MetricsFpsErrLast) {
                $script:MetricsFpsErrLast = $sample.fpsErr
                $script:MetricsFpsErrAt = Get-Date
                Write-AppLog ('实时 FPS 不可用：' + $sample.fpsErr) 'WARN'
            } elseif ($script:MetricsFpsErrAt -and ((Get-Date) - $script:MetricsFpsErrAt).TotalSeconds -ge 120) {
                $script:MetricsFpsErrAt = Get-Date
                Write-AppLog ('实时 FPS 仍不可用：' + $sample.fpsErr) 'WARN'
            }
        } elseif ($script:MetricsFpsErrLast) {
            $script:MetricsFpsErrLast = ''
            $script:MetricsFpsErrAt = $null
            Write-AppLog '实时 FPS 已恢复'
        }
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
    $script:MetricsFpsFixed = $false
    # 实时页选的「目标进程」优先（固定目标，不跟随前台）；没选才退回「采集页上次的进程」当备选
    $rt = 0
    try { $rt = [int]$script:Cfg.rtTargetPid } catch { }
    if ($rt -gt 0) {
        try {
            $p = Get-Process -Id $rt -ErrorAction Stop
            $script:MetricsFpsPid = $p.Id
            $script:MetricsFpsName = $p.ProcessName
            $script:MetricsFpsFixed = $true
        } catch { $script:Cfg.rtTargetPid = 0 }
    }
    if (-not $script:MetricsFpsFixed) {
        try {
            $lp = [int]$script:Cfg.lastPid
            if ($lp -gt 0) {
                $p = Get-Process -Id $lp -ErrorAction Stop
                $script:MetricsFpsPid = $p.Id
                $script:MetricsFpsName = $p.ProcessName
            }
        } catch { }
    }
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
        $script:MetricsCaps.fpsFixed = [bool]$script:MetricsFpsFixed
    }
    Start-MetricsWorker
    Send-MetricsCaps
    $fpsNote = if ($script:MetricsPmPath -and $script:MetricsFpsCsv) {
        if ($script:MetricsFpsFixed) {
            'FPS 固定目标 ' + $script:MetricsFpsName + '(' + $script:MetricsFpsPid + ')'
        } else {
            $fb = if ($script:MetricsFpsPid -gt 0) { ('；无前台时退回 ' + $script:MetricsFpsName + '(' + $script:MetricsFpsPid + ')') } else { '' }
            'FPS 跟随前台应用' + $fb
        }
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
        'metricsTarget' {
            # 0 = 跟随前台；>0 = 固定目标。正在采样时重启一次，让新目标立刻生效
            $pid2 = 0
            if ($null -ne $Msg.pid) { try { $pid2 = [int]$Msg.pid } catch { $pid2 = 0 } }
            if ($pid2 -lt 0) { $pid2 = 0 }
            $wasRunning = [bool]$script:MetricsRunning
            $script:Cfg.rtTargetPid = $pid2
            $script:Cfg.rtTargetName = [string]$Msg.name
            try { Save-Config } catch { }
            if ($wasRunning) {
                Stop-MetricsSampler
                Start-Sleep -Milliseconds 120
                Start-MetricsSampler
            }
            Send-ToUi @{ type = 'metricsCaps'; caps = $script:MetricsCaps; running = [bool]$script:MetricsRunning }
            Write-AppLog ('实时监控目标：' + $(if ($pid2 -gt 0) { [string]$Msg.name + '(' + $pid2 + ')' } else { '跟随前台窗口' }))
        }
    }
}
