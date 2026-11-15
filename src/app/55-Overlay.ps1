# 实时监控浮窗（1.5.0 · 批次 B）
#
# 形态照 NVIDIA app 的浮层：无边框、置顶、半透明、可拖动，双击收成小胶囊。
# 只读遥测，**不是注入式覆盖层**：它只是一个普通置顶窗口。
#   注意：独占全屏（Exclusive Fullscreen）下普通窗口看不到，无边框/窗口化才显示；
#   本项目不会为此加注入覆盖层（那类东西正是触发厂商反作弊/画质开关问题的来源）。
#
# 数据：复用 35-Metrics.ps1 的采样器，用「消费者计数」保证浮窗开着就会采样。
# 交互：Ctrl+Alt+M 显隐（轮询 GetAsyncKeyState，不装键盘钩子）；位置/透明度/折叠状态存配置。

$script:OverlayForm = $null
$script:OverlayTimer = $null
$script:OverlayVisible = $false
$script:OverlayCollapsed = $false
$script:OverlayDragging = $false
$script:OverlayDragOffset = $null
$script:OverlayHotkeyWasDown = $false
$script:OverlayControls = $null

$script:OverlayRowDefs = @(
    @{ key = 'fps'; label = 'FPS'; max = 0 }
    @{ key = 'cpu'; label = 'CPU'; max = 100 }
    @{ key = 'gpu'; label = 'GPU'; max = 100 }
)

function Get-OverlayCfg {
    if (-not $script:Cfg.overlay) {
        $script:Cfg.overlay = @{ visible = $false; x = -1; y = -1; opacity = 0.9; collapsed = $false }
    }
    if (-not $script:Cfg.overlay.ContainsKey('opacity')) { $script:Cfg.overlay.opacity = 0.9 }
    if (-not $script:Cfg.overlay.ContainsKey('collapsed')) { $script:Cfg.overlay.collapsed = $false }
    return $script:Cfg.overlay
}

function Initialize-OverlayNative {
    if ('PerfOverlayNative' -as [type]) { return }
    $cs = @(
        'using System;'
        'using System.Runtime.InteropServices;'
        'public static class PerfOverlayNative {'
        '    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);'
        '}'
    ) -join "`n"
    try { Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop } catch { }
}

function New-OverlayBar {
    param([System.Drawing.Color]$Color)
    $p = New-Object System.Windows.Forms.Panel
    $p.BackColor = $Color
    return $p
}

function Build-OverlayForm {
    $cfg = Get-OverlayCfg
    $script:OverlayCollapsed = [bool]$cfg.collapsed

    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.Text = 'PerfCapture 浮窗'
    $f.BackColor = [System.Drawing.Color]::FromArgb(26, 28, 34)
    $f.Opacity = [double]$cfg.opacity
    $f.MinimizeBox = $false
    $f.MaximizeBox = $false

    $font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $fontSmall = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)

    $controls = @{}
    $rows = @()
    $y = 10
    foreach ($def in $script:OverlayRowDefs) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $def.label
        $lbl.Font = $font
        $lbl.ForeColor = [System.Drawing.Color]::FromArgb(170, 176, 188)
        $lbl.AutoSize = $false
        $lbl.TextAlign = 'MiddleLeft'
        $lbl.SetBounds(12, $y, 40, 18)

        $track = New-Object System.Windows.Forms.Panel
        $track.BackColor = [System.Drawing.Color]::FromArgb(52, 56, 66)
        $track.SetBounds(56, $y + 6, 118, 6)

        $fill = New-Object System.Windows.Forms.Panel
        $fill.BackColor = [System.Drawing.Color]::FromArgb(134, 114, 186)
        $fill.SetBounds(0, 0, 0, 6)
        $track.Controls.Add($fill)

        $val = New-Object System.Windows.Forms.Label
        $val.Text = '—'
        $val.Font = $fontSmall
        $val.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
        $val.AutoSize = $false
        $val.TextAlign = 'MiddleRight'
        $val.SetBounds(178, $y, 58, 18)

        $f.Controls.Add($lbl)
        $f.Controls.Add($track)
        $f.Controls.Add($val)
        $rows += @{ def = $def; label = $lbl; track = $track; fill = $fill; value = $val }
        $y += 30
    }

    # 拖动 / 双击收起
    $dragStart = {
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $script:OverlayDragging = $true
            $script:OverlayDragOffset = $e.Location
        }
    }
    $dragMove = {
        param($sender, $e)
        if ($script:OverlayDragging -and $script:OverlayForm) {
            $pt = [System.Windows.Forms.Cursor]::Position
            $script:OverlayForm.Location = New-Object System.Drawing.Point(
                ($pt.X - $script:OverlayDragOffset.X), ($pt.Y - $script:OverlayDragOffset.Y))
        }
    }
    $dragEnd = {
        param($sender, $e)
        if ($script:OverlayDragging) {
            $script:OverlayDragging = $false
            Save-OverlayPosition
        }
    }
    $f.add_MouseDown($dragStart)
    $f.add_MouseMove($dragMove)
    $f.add_MouseUp($dragEnd)
    $f.add_DoubleClick({
        param($sender, $e)
        Toggle-OverlayCollapsed
    })

    # 子控件也要能拖（否则只有边框区域能拖）
    foreach ($c in @($f.Controls)) {
        $c.add_MouseDown($dragStart)
        $c.add_MouseMove($dragMove)
        $c.add_MouseUp($dragEnd)
        $c.add_DoubleClick({ param($s, $e) Toggle-OverlayCollapsed })
    }

    $script:OverlayForm = $f
    $script:OverlayControls = $rows
    Apply-OverlayLayout

    # 位置：有记忆就用，否则贴右上
    $x = [int]$cfg.x; $yPos = [int]$cfg.y
    if ($x -lt 0 -or $yPos -lt 0) {
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $x = $wa.Right - $f.Width - 24
        $yPos = $wa.Top + 24
    }
    $f.Location = New-Object System.Drawing.Point($x, $yPos)
    return $f
}

function Apply-OverlayLayout {
    $f = $script:OverlayForm
    if (-not $f) { return }
    if ($script:OverlayCollapsed) {
        $f.Size = New-Object System.Drawing.Size(250, 40)
        $i = 0
        foreach ($row in $script:OverlayControls) {
            $show = ($i -eq 0)
            $row.label.Visible = $show
            $row.track.Visible = $show
            $row.value.Visible = $show
            $i++
        }
    } else {
        $f.Size = New-Object System.Drawing.Size(250, 110)
        foreach ($row in $script:OverlayControls) {
            $row.label.Visible = $true
            $row.track.Visible = $true
            $row.value.Visible = $true
        }
    }
}

function Save-OverlayPosition {
    $f = $script:OverlayForm
    if (-not $f) { return }
    try {
        $cfg = Get-OverlayCfg
        $cfg.x = $f.Left
        $cfg.y = $f.Top
        Save-Config
    } catch { }
}

function Update-OverlayReadout {
    $f = $script:OverlayForm
    if (-not $f -or -not $script:OverlayControls) { return }
    $s = $null
    if ($script:MetricsSamples -and $script:MetricsSamples.Count -gt 0) {
        $s = $script:MetricsSamples[$script:MetricsSamples.Count - 1]
    }
    foreach ($row in $script:OverlayControls) {
        switch ($row.def.key) {
            'fps' {
                # 实时 FPS：宿主 35-Metrics.ps1 增量 tail PresentMon CSV 得到 s.fps
                if ($s -and $null -ne $s.fps) {
                    $row.value.Text = ('{0:0.#} FPS' -f [double]$s.fps)
                    $row.fill.Width = [int]([math]::Min(1.0, ([double]$s.fps / 240.0)) * $row.track.Width)
                } else {
                    $row.value.Text = '—'
                    $row.fill.Width = 0
                }
            }
            'cpu' {
                if ($s -and $null -ne $s.cpu) {
                    $row.value.Text = ('{0} %' -f [int]$s.cpu)
                    $row.fill.Width = [int]([math]::Min(1.0, ($s.cpu / 100.0)) * $row.track.Width)
                } else {
                    $row.value.Text = '—'
                    $row.fill.Width = 0
                }
            }
            'gpu' {
                if ($s -and $null -ne $s.gpu) {
                    $row.value.Text = ('{0} %' -f [int]$s.gpu)
                    $row.fill.Width = [int]([math]::Min(1.0, ($s.gpu / 100.0)) * $row.track.Width)
                } else {
                    $row.value.Text = '—'
                    $row.fill.Width = 0
                }
            }
        }
    }
}

function Start-OverlayTimer {
    if ($script:OverlayTimer) { return }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.add_Tick({
        try {
            Update-OverlayReadout
            # Ctrl+Alt+M（不装键盘钩子，只读按键状态）
            if ('PerfOverlayNative' -as [type]) {
                $ctrl = ([PerfOverlayNative]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0
                $alt = ([PerfOverlayNative]::GetAsyncKeyState(0x12) -band 0x8000) -ne 0
                $m = ([PerfOverlayNative]::GetAsyncKeyState(0x4D) -band 0x8000) -ne 0
                $down = $ctrl -and $alt -and $m
                if ($down -and -not $script:OverlayHotkeyWasDown) { Toggle-Overlay }
                $script:OverlayHotkeyWasDown = $down
            }
        } catch {
            Write-AppLog ('浮窗计时器异常: ' + $_.Exception.Message) 'WARN'
            Stop-OverlayTimer
        }
    })
    $timer.Start()
    $script:OverlayTimer = $timer
}

function Stop-OverlayTimer {
    if ($script:OverlayTimer) {
        try { $script:OverlayTimer.Stop(); $script:OverlayTimer.Dispose() } catch { }
        $script:OverlayTimer = $null
    }
}

function Toggle-OverlayCollapsed {
    $script:OverlayCollapsed = -not $script:OverlayCollapsed
    Apply-OverlayLayout
    try {
        $cfg = Get-OverlayCfg
        $cfg.collapsed = $script:OverlayCollapsed
        Save-Config
    } catch { }
    Write-AppLog (('浮窗{0}' -f $(if ($script:OverlayCollapsed) { '已收起' } else { '已展开' })))
}

function Show-Overlay {
    Initialize-OverlayNative
    if (-not $script:OverlayForm) { Build-OverlayForm | Out-Null }
    $script:OverlayForm.Show()
    $script:OverlayForm.TopMost = $true
    $script:OverlayVisible = $true
    Start-OverlayTimer
    Set-MetricsConsumer -Name 'overlay' -On $true
    Update-OverlayReadout
    try {
        $cfg = Get-OverlayCfg
        $cfg.visible = $true
        Save-Config
    } catch { }
    Write-AppLog '浮窗已显示（Ctrl+Alt+M 收起/展开；独占全屏下不可见）'
}

function Hide-Overlay {
    if ($script:OverlayForm) { try { $script:OverlayForm.Hide() } catch { } }
    $script:OverlayVisible = $false
    Stop-OverlayTimer
    Set-MetricsConsumer -Name 'overlay' -On $false
    try {
        $cfg = Get-OverlayCfg
        $cfg.visible = $false
        Save-Config
    } catch { }
    Write-AppLog '浮窗已隐藏'
}

function Toggle-Overlay {
    if ($script:OverlayVisible) { Hide-Overlay } else { Show-Overlay }
}

function Invoke-OverlayCommand {
    param($Msg)
    switch ($Msg.cmd) {
        'overlayToggle' { Toggle-Overlay }
        'overlayShow' { Show-Overlay }
        'overlayHide' { Hide-Overlay }
    }
    Send-ToUi @{ type = 'overlayState'; visible = [bool]$script:OverlayVisible; collapsed = [bool]$script:OverlayCollapsed }
}

# 启动时若上次是开着的，就恢复（位置也一并恢复）
function Restore-OverlayIfNeeded {
    try {
        $cfg = Get-OverlayCfg
        if ($cfg.visible) { Show-Overlay }
    } catch { }
}
