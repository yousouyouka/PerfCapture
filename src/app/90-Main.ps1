# 收尾与主循环

# ForceExit：只有托盘「退出」这类真正的退出动作才置 true；
# 普通关闭在 closeToTray 开启时会被改成「收起到托盘」。
$script:ForceExit = $false

# 任务栏/Alt-Tab 隐藏：只改扩展样式，不动 ShowInTaskbar（后者会重建句柄，还原时闪回）。
# 第一次收起时才编译，正常启动不为它付钱。
$trayWinCs = @'
using System;
using System.Runtime.InteropServices;
public class PcTrayWindow {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    // 任务栏按钮的权威开关：只改 WS_EX_TOOLWINDOW 时，已经显示过的窗口任务栏不会立即刷新，
    // 必须显式 DeleteTab；还原时 AddTab。两者都不碰窗口句柄与可见性。
    [ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090")]
    public class CTaskbarList { }

    [ComImport, Guid("56FDF342-FD6D-11d0-958A-006097C9A090"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ITaskbarList {
        void HrInit();
        void AddTab(IntPtr hwnd);
        void DeleteTab(IntPtr hwnd);
        void ActivateTab(IntPtr hwnd);
        void SetActiveAlt(IntPtr hwnd);
    }

    private static ITaskbarList _taskbar;
    private static ITaskbarList Taskbar() {
        if (_taskbar == null) {
            _taskbar = (ITaskbarList)new CTaskbarList();
            _taskbar.HrInit();
        }
        return _taskbar;
    }

    const int GWL_EXSTYLE = -20;
    const int WS_EX_TOOLWINDOW = 0x00000080;
    const int WS_EX_APPWINDOW = 0x00040000;
    const uint SWP_NOSIZE = 0x0001;
    const uint SWP_NOZORDER = 0x0004;
    const uint SWP_NOACTIVATE = 0x0010;
    const uint SWP_FRAMECHANGED = 0x0020;
    const uint SWP_SHOWWINDOW = 0x0040;

    public static void Hide(IntPtr h, int x, int y) {
        int ex = GetWindowLong(h, GWL_EXSTYLE);
        SetWindowLong(h, GWL_EXSTYLE, (ex | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW);
        SetWindowPos(h, IntPtr.Zero, x, y, 0, 0,
            SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
        try { Taskbar().DeleteTab(h); } catch { }
    }

    public static void Show(IntPtr h, int x, int y) {
        int ex = GetWindowLong(h, GWL_EXSTYLE);
        SetWindowLong(h, GWL_EXSTYLE, (ex & ~WS_EX_TOOLWINDOW) | WS_EX_APPWINDOW);
        SetWindowPos(h, IntPtr.Zero, x, y, 0, 0,
            SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
        try { Taskbar().AddTab(h); } catch { }
    }
}
'@

function Ensure-PcTrayWindow {
    if ('PcTrayWindow' -as [type]) { return $true }
    try { Add-Type -TypeDefinition $trayWinCs -Language CSharp; return $true }
    catch { Write-AppLog ('托盘窗口样式编译失败: ' + $_.Exception.Message) 'WARN'; return $false }
}

# 收起主窗口到托盘。不能 Hide()/Visible=false —— ShowDialog 的条件是窗口仍可见；
# 也不能改 ShowInTaskbar（会重建句柄，还原时闪回）。
# 做法：记下位置与最大化状态 → 移出屏幕 + Opacity=0 + WS_EX_TOOLWINDOW（任务栏/Alt-Tab 都不占位）。
function Hide-PerfWindowToTray {
    if (Get-Command Initialize-NetTray -ErrorAction SilentlyContinue) {
        try { Initialize-NetTray } catch { }
    }
    if (-not $script:NetTray) {
        Write-AppLog '托盘图标不可用，窗口保持显示（避免没有入口可恢复）' 'WARN'
        return
    }
    if (-not (Get-Command Ensure-PcTrayWindow -ErrorAction SilentlyContinue) -or -not (Ensure-PcTrayWindow)) {
        Write-AppLog '窗口样式辅助不可用，保持显示' 'WARN'
        return
    }
    try {
        if (-not $script:TrayHidden) {
            $script:TrayHomeState = if ($form.WindowState -eq 'Maximized') { 'Maximized' } else { 'Normal' }
            if ($form.WindowState -eq 'Normal') { $script:TrayHomeLocation = $form.Location }
            else { $script:TrayHomeLocation = $form.RestoreBounds.Location }
        }
        $script:TrayHidden = $true
        # 先透明再改样式/删任务栏页签：Opacity 变化会触发 WinForms 重绘，放在 DeleteTab 之后
        # 有可能把页签又加回来。
        $form.Opacity = 0
        [PcTrayWindow]::Hide($form.Handle, -32000, -32000)
        Write-AppLog '窗口已缩小到托盘'
    } catch {
        Write-AppLog ('缩小到托盘失败: ' + $_.Exception.Message) 'WARN'
    }
}

# ---------- 收尾 ----------
$form.Add_FormClosing({
    param($s, $e)
    # 关闭到托盘（2.2.2）：取消关闭并收起窗口；采集进行中也不打断（真退出走托盘菜单）
    if (-not $script:ForceExit -and [bool]$script:Cfg.closeToTray) {
        $e.Cancel = $true
        Hide-PerfWindowToTray
        return
    }
    $script:CloseT0 = Get-Date
    try { Write-BootMark '关闭开始' } catch { }
    if ($script:Job) {
        $r = [System.Windows.Forms.MessageBox]::Show('正在采集，确定要中止吗？', 'PerfCapture', 'YesNo', 'Question')
        if ($r -ne 'Yes') { $script:ForceExit = $false; $e.Cancel = $true; return }
        Stop-Capture
    }
    # 注销全局热键：退出后不该继续占着系统组合键
    try { if (Get-Command Unregister-PerfHotkeys -ErrorAction SilentlyContinue) { Unregister-PerfHotkeys } } catch { }
    # 网络统计退出落盘：不落盘会丢掉最后一次落盘之后的全部增量
    try { if (Get-Command Flush-NetStatsOnExit -ErrorAction SilentlyContinue) { Flush-NetStatsOnExit } } catch { }
    # webhook（2.2.11）：停计时器、结束未完成的后台发送，避免进程被后台 runspace 拖住
    try { if (Get-Command Stop-PerfWebhookJobs -ErrorAction SilentlyContinue) { Stop-PerfWebhookJobs } } catch { }
    try {
        $script:Cfg.windowW = [int]($form.ClientSize.Width / $script:DpiScale)
        $script:Cfg.windowH = [int]($form.ClientSize.Height / $script:DpiScale)
        if ($form.WindowState -eq 'Normal') { Save-Config }
    } catch { }
    # 先停看护计时器：否则退出清理杀进程时会被误判成「意外退出」又拉起来。
    try {
        if ($script:ExtWatchTimer) { $script:ExtWatchTimer.Stop(); $script:ExtWatchTimer.Dispose(); $script:ExtWatchTimer = $null }
    } catch { }
    try {
        if ($script:BootFallbackTimer) { $script:BootFallbackTimer.Stop(); $script:BootFallbackTimer.Dispose(); $script:BootFallbackTimer = $null }
    } catch { }
    # 退出时清掉所有在跑的扩展进程，绝不留孤儿（扩展隔离进程的兜底清理）
    try { if (Get-Command Stop-AllExtensionProcesses -ErrorAction SilentlyContinue) { Stop-AllExtensionProcesses } } catch { }
    try { $script:Mutex.ReleaseMutex() } catch { }
    try { Write-AppLog ('关闭清理耗时: ' + [int]((Get-Date) - $script:CloseT0).TotalMilliseconds + ' ms') } catch { }
})

# ---------- 首屏之后的后台初始化（2.2.2）----------
# 平台画像、扩展自愈/自启、看护计时器都不影响第一帧，却可能各要几十到几百毫秒。
# 以前它们在 ShowDialog 之前同步跑，用户看到的就是「点了图标半天没反应」。
# 现在改由一次性计时器在窗口显示后执行：仍在 UI 线程、只跑一次、失败只记日志。
$script:BootDeferredDone = $false
function Invoke-DeferredStartup {
    if ($script:BootDeferredDone) { return }
    $script:BootDeferredDone = $true

    # 网络统计持久化（2.2.0）：常驻 1 Hz 计数器差分只在内存累加，每 60 秒原子落盘一次。
    # 2.2.3：起 runspace + 第一次枚举网卡并不便宜，挪到这里，保证首屏先出来。
    try {
        if (Get-Command Initialize-NetPersistence -ErrorAction SilentlyContinue) { Initialize-NetPersistence }
        if (Get-Command Set-NetConsumer -ErrorAction SilentlyContinue) { Set-NetConsumer 'persist' $true }
        if (Get-Command Set-NetReverseDns -ErrorAction SilentlyContinue) { Set-NetReverseDns ([bool]$script:Cfg.netReverseDns) }
    } catch { }

    # 开机自启：按配置校正注册表（配置是唯一事实来源；开关切换时也会即时写入）
    try { if (Get-Command Sync-PerfAutoStart -ErrorAction SilentlyContinue) { Sync-PerfAutoStart } } catch { }

    # 平台覆盖（v2.1.10）：记录一次画像，支持时能一眼区分「不在覆盖范围」与「读取失败」。
    # 不阻止启动：表外组合仍可用帧采集等基线功能，只是相关指标如实 N/A（规则文档 §1）。
    try {
        if (Get-Command Get-PlatformProfile -ErrorAction SilentlyContinue) {
            $plat = Get-PlatformProfile
            $platTxt = '平台：' + $plat.osName + ' build ' + $plat.osBuild + ' · CPU ' + $plat.cpuVendor + ' · GPU ' + $plat.gpuVendor
            if ($plat.systemVendor) { $platTxt += ' · 整机 ' + $plat.systemVendor + ' ' + $plat.systemModel }
            if (@($plat.reasons).Count -gt 0) { $platTxt += ' · 不在覆盖范围：' + (@($plat.reasons) -join ',') }
            Write-AppLog $platTxt
        }
    } catch { }

    # 启动自愈：撤销「已装但未启用」扩展留在系统里的注册痕迹。
    # 旧版本关闭只清进程不清注册，升级后系统里仍残留指向副本的 Vulkan 隐式层，
    # 游戏照旧加载它、DLSS 照旧消失。这里做一次自愈，用户不需要手动操作。
    # 必须在 Start-EnabledExtensions 之前：启用中的扩展需要这些注册（RTSS 靠它做 overlay）。
    try { if (Get-Command Clear-DisabledExtensionTraces -ErrorAction SilentlyContinue) { [void](Clear-DisabledExtensionTraces) } }
    catch { Write-AppLog ('启动自愈清理失败: ' + $_.Exception.Message) 'WARN' }

    # 扩展自启：启动时恢复所有「已启用」且 autoStart 的托管扩展；失败只记日志并回退基线，不阻断界面。
    try { if (Get-Command Start-EnabledExtensions -ErrorAction SilentlyContinue) { Start-EnabledExtensions } }
    catch { Write-AppLog ('扩展自启失败: ' + $_.Exception.Message) 'WARN' }

    # 运行期看护（§10.5）：每 2 秒检查一次「本软件拉起、用户仍启用」的扩展进程。
    # 意外退出 → 指数退避重启最多 2 次；仍失败转 failed 并回退基线。
    # 独立计时器而不是挂在采集/更新计时器上：那些会被采集任务停掉，看护必须全程在。
    try {
        if (Get-Command Invoke-ExtensionWatchdogTick -ErrorAction SilentlyContinue) {
            $script:ExtWatchTimer = New-Object System.Windows.Forms.Timer
            $script:ExtWatchTimer.Interval = 2000
            $script:ExtWatchTimer.Add_Tick({
                try { Invoke-ExtensionWatchdogTick }
                catch { Write-AppLog ('扩展看护异常: ' + $_.Exception.Message) 'WARN' }
            })
            $script:ExtWatchTimer.Start()
        }
    } catch { Write-AppLog ('扩展看护计时器启动失败: ' + $_.Exception.Message) 'WARN' }

    try { Write-BootMark '后台初始化完成' } catch { }
}

# 2.2.3：延迟初始化等界面真正 ready 后再启动。以前在 ShowDialog 前 Start，
# 计时器会在 WebView2 初始化的 DoEvents 泵里提前触发，仍然抢首屏。
function Start-BootDeferred {
    if ($script:BootDeferredDone -or $script:BootTimer) { return }
    try {
        $script:BootTimer = New-Object System.Windows.Forms.Timer
        $script:BootTimer.Interval = 120
        $script:BootTimer.Add_Tick({
            $script:BootTimer.Stop()
            $script:BootTimer.Dispose()
            $script:BootTimer = $null
            try { Invoke-DeferredStartup } catch { Write-AppLog ('后台初始化失败: ' + $_.Exception.Message) 'WARN' }
        })
        $script:BootTimer.Start()
    } catch { Write-AppLog ('后台初始化计时器启动失败: ' + $_.Exception.Message) 'WARN' }
}

# 2.2.7：界面 ready 消息可能因 WebView2 异常永远不来。8 秒兜底跑一次后台初始化，
# 否则扩展自启、自启校正、网络持久化会被永久跳过（首屏已经出来，兜底不影响观感）。
try {
    $script:BootFallbackTimer = New-Object System.Windows.Forms.Timer
    $script:BootFallbackTimer.Interval = 8000
    $script:BootFallbackTimer.Add_Tick({
        $script:BootFallbackTimer.Stop()
        $script:BootFallbackTimer.Dispose()
        $script:BootFallbackTimer = $null
        if ($script:BootDeferredDone -or $script:BootTimer) { return }
        Write-AppLog '界面 ready 超时，走兜底初始化' 'WARN'
        try { Invoke-DeferredStartup } catch { Write-AppLog ('后台初始化失败: ' + $_.Exception.Message) 'WARN' }
    })
    $script:BootFallbackTimer.Start()
} catch { }

# 主循环：$form.ShowDialog() 只在窗口被**用户关掉**时才应该返回。
# 万一有代码路径让它提前返回（例如误把窗口设成不可见 —— 模态循环的条件就是"仍可见"），
# 这里立刻重新进入循环，绝不让程序"自己关掉"（1.8.1 导出长图踩过这个坑）。
$script:UserClosed = $false
$form.Add_FormClosed({ $script:UserClosed = $true })

while (-not $form.IsDisposed -and -not $script:UserClosed) {
    [void]$form.ShowDialog()
    if (-not $script:UserClosed -and -not $form.IsDisposed) {
        Write-AppLog '主循环意外返回（窗口不是被用户关掉的），重新进入' 'WARN'
        try { if (-not $form.Visible) { $form.Show() } } catch { }
    }
}
