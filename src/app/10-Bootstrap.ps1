# 启动引导：单实例、提权、工作目录、WebView2 依赖加载

# ---------- 提权（PresentMon 需要 ETW 会话） ----------
# 顺序很关键：**先提权、再占单实例锁**。之前是先占锁再提权，父进程退出前子进程就来抢锁，
# 于是"明明没有进程在跑却提示已经在运行"。
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $self = (Get-Process -Id $PID).Path
    if (-not $self) { $self = 'powershell.exe' }
    Start-Process $self -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', ('"' + $script:EntryPath + '"')
    ) | Out-Null
    exit
}

# ---------- 单实例 ----------
# Local\ 作用域（同一次登录会话）；被上次异常退出遗留下来的锁会抛 AbandonedMutexException，
# 它的语义是"锁被废弃、现在归你"，必须当作拿到，否则又会误报"已经在运行"。
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\PerfCapture.SingleInstance')
$owned = $false
try {
    $owned = $script:Mutex.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
    $owned = $true
} catch { }
if (-not $owned) {
    [System.Windows.Forms.MessageBox]::Show('PerfCapture 已经在运行。', 'PerfCapture') | Out-Null
    exit
}

foreach ($p in @($script:OutDir, $script:TempDir)) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

# ---------- WebView2 依赖 ----------
$env:PATH = $script:LibDir + ';' + $env:PATH
# 内置工具优先：打包后 presentmon.exe 随 tools\ 分发，放进 PATH 让引擎的 Get-Command 能命中，
# 用户端无需再 winget install；若系统已装 WinGet 版，引擎仍会优先用那个（版本一致即可）。
if ($script:ToolsDir -and (Test-Path $script:ToolsDir) -and ($env:PATH -notlike ('*' + $script:ToolsDir + '*'))) {
    $env:PATH = $script:ToolsDir + ';' + $env:PATH
}
try { [System.Environment]::CurrentDirectory = $script:LibDir } catch { }
$coreDll = Join-Path $LibDir 'Microsoft.Web.WebView2.Core.dll'
$wfDll   = Join-Path $LibDir 'Microsoft.Web.WebView2.WinForms.dll'
if (-not (Test-Path $coreDll) -or -not (Test-Path $wfDll)) {
    [System.Windows.Forms.MessageBox]::Show("缺少 WebView2 组件，请确认 lib\ 目录完整。`n$LibDir", 'PerfCapture') | Out-Null
    exit
}
if (-not ('Microsoft.Web.WebView2.WinForms.WebView2' -as [type])) {
    # WebView2 的 WinForms 包装引用了 System.Windows.Forms；先确保它加载好，否则 Add-Type 会失败，
    # 之后 50-Host 的 New-Object 只会报一句「找不到类型」，看不出真因。
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { }
    try {
        Add-Type -Path $coreDll -ErrorAction Stop
        Add-Type -Path $wfDll -ErrorAction Stop
    } catch {
        $msg = 'WebView2 依赖加载失败: ' + $_.Exception.Message
        Write-Host $msg -ForegroundColor Red
        try {
            [IO.File]::AppendAllText((Join-Path $env:TEMP 'perfcapture-wv2err.log'),
                ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $msg + "`r`n"), (New-Object Text.UTF8Encoding($true)))
        } catch { }
    }
}
