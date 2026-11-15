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
    try { $script:Mutex.ReleaseMutex() } catch { }
})

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
