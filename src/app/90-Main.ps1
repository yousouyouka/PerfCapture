# 收尾与主循环

# ---------- 收尾 ----------
$form.Add_FormClosing({
    param($s, $e)
    if ($script:Job) {
        $r = [System.Windows.Forms.MessageBox]::Show('正在采集，确定要中止吗？', 'PerfCapture', 'YesNo', 'Question')
        if ($r -ne 'Yes') { $e.Cancel = $true; return }
        Stop-Capture
    }
    try {
        $script:Cfg.windowW = [int]($form.ClientSize.Width / $script:DpiScale)
        $script:Cfg.windowH = [int]($form.ClientSize.Height / $script:DpiScale)
        if ($form.WindowState -eq 'Normal') { Save-Config }
    } catch { }
    # 退出时清掉所有在跑的扩展进程，绝不留孤儿（扩展隔离进程的兜底清理）
    try { if (Get-Command Stop-AllExtensionProcesses -ErrorAction SilentlyContinue) { Stop-AllExtensionProcesses } } catch { }
    try { $script:Mutex.ReleaseMutex() } catch { }
})

# 启动自愈：撤销「已装但未启用」扩展留在系统里的注册痕迹。
# 旧版本关闭只清进程不清注册，升级后系统里仍残留指向副本的 Vulkan 隐式层，
# 游戏照旧加载它、DLSS 照旧消失。这里做一次自愈，用户不需要手动操作。
# 必须在 Start-EnabledExtensions 之前：启用中的扩展需要这些注册（RTSS 靠它做 overlay）。
try { if (Get-Command Clear-DisabledExtensionTraces -ErrorAction SilentlyContinue) { [void](Clear-DisabledExtensionTraces) } }
catch { Write-AppLog ('启动自愈清理失败: ' + $_.Exception.Message) 'WARN' }

# 扩展自启：启动时恢复所有「已启用」且 autoStart 的托管扩展；失败只记日志并回退基线，不阻断界面。
try { if (Get-Command Start-EnabledExtensions -ErrorAction SilentlyContinue) { Start-EnabledExtensions } }
catch { Write-AppLog ('扩展自启失败: ' + $_.Exception.Message) 'WARN' }

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
