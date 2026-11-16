# 实时监控浮窗（1.5.0 批次 B / 1.5.4 批次 A 扩展）
#
# 形态照 NVIDIA app 的浮层：无边框、置顶、半透明、可拖动，双击收成小胶囊。
# 只读遥测，**不是注入式覆盖层**：它只是一个普通置顶窗口。
#   注意：独占全屏（Exclusive Fullscreen）下普通窗口看不到，无边框/窗口化才显示；
#   本项目不会为此加注入覆盖层（那类东西正是触发厂商反作弊/画质开关问题的来源）。
#
# 数据：复用 35-Metrics.ps1 的采样器，用「消费者计数」保证浮窗开着就会采样。
# 交互：热键可配（默认 Ctrl+Alt+M，轮询 GetAsyncKeyState，不装键盘钩子）；
#       位置支持九宫格预设 / 横纵百分比 / 直接填像素；不透明度 / 字号 / 字体颜色可配，全部存配置。

$script:OverlayForm = $null
$script:OverlayTimer = $null
$script:OverlayVisible = $false
$script:OverlayCollapsed = $false
$script:OverlayDragging = $false
$script:OverlayDragOffset = $null
$script:OverlayHotkeyWasDown = $false
$script:OverlayControls = $null
$script:OverlayStyle = $null

$script:OverlayRowDefs = @(
    @{ key = 'fps'; label = 'FPS'; max = 0 }
    @{ key = 'cpu'; label = 'CPU'; max = 100 }
    @{ key = 'gpu'; label = 'GPU'; max = 100 }
    @{ key = 'mem'; label = 'MEM'; max = 100 }
)

$script:OverlayMetricKeys = @('fps', 'cpu', 'gpu', 'mem')

# 只显示用户勾选的指标族；空集合兜底 FPS，避免浮窗变空白
function Get-OverlayRowSet {
    param($Cfg)
    $keys = @()
    if ($null -ne $Cfg.metrics) { $keys = @($Cfg.metrics) }
    if (-not $keys.Count) { $keys = @('fps') }
    $rows = @($script:OverlayRowDefs | Where-Object { $keys -contains $_.key })
    if (-not $rows.Count) { $rows = @($script:OverlayRowDefs[0]) }
    return $rows
}

$script:OverlayAnchors = @('tl', 't', 'tr', 'l', 'c', 'r', 'bl', 'b', 'br')

# ---------- 配置 ----------
function Get-OverlayCfg {
    if (-not $script:Cfg.overlay) { $script:Cfg.overlay = @{} }
    $o = $script:Cfg.overlay
    $def = [ordered]@{
        visible = $false; x = -1; y = -1; opacity = 90; collapsed = $false
        anchor = 'tr'; px = 100; py = 0
        fontSize = 'normal'; fontColor = 'white'; layout = 'linear'
    }
    foreach ($k in $def.Keys) { if ($null -eq $o.$k) { $o.$k = $def[$k] } }
    if (-not $o.hotkey) { $o.hotkey = @{ ctrl = $true; alt = $true; shift = $false; key = 'M' } }
    if (-not $o.hotkey.key) { $o.hotkey.key = 'M' }
    # 浮窗显示哪些指标族（界面「显示指标」勾选后按族折算，页面与浮窗共用一份）
    $mk = @()
    if ($null -ne $o.metrics) { $mk = @(@($o.metrics) | ForEach-Object { ([string]$_).ToLower() } | Where-Object { $script:OverlayMetricKeys -contains $_ } | Select-Object -Unique) }
    if (-not $mk.Count) { $mk = @('fps', 'cpu', 'gpu', 'mem') }
    $o.metrics = $mk
    # 老配置里 opacity 是 0..1，迁移到百分比
    $op = 90.0
    try { $op = [double]$o.opacity } catch { }
    if ($op -le 1) { $op = $op * 100 }
    $o.opacity = [int][math]::Min(100, [math]::Max(20, [math]::Round($op)))
    if ($o.anchor -notin $script:OverlayAnchors -and $o.anchor -ne 'custom') { $o.anchor = 'tr' }
    if ($o.fontSize -notin @('small', 'normal', 'large')) { $o.fontSize = 'normal' }
    if ($o.fontColor -notin @('white', 'gray', 'green', 'yellow')) { $o.fontColor = 'white' }
    if ($o.layout -ne 'linear') { $o.layout = 'linear' }
    return $o
}

function Get-OverlayStyle {
    param($Cfg)
    $size = switch ($Cfg.fontSize) { 'small' { 8 } 'large' { 11 } default { 9 } }
    $color = switch ($Cfg.fontColor) {
        'gray' { [System.Drawing.Color]::FromArgb(176, 180, 190) }
        'green' { [System.Drawing.Color]::FromArgb(150, 226, 170) }
        'yellow' { [System.Drawing.Color]::FromArgb(240, 214, 140) }
        default { [System.Drawing.Color]::FromArgb(235, 238, 245) }
    }
    return @{ size = $size; small = [math]::Max(6, $size - 1); color = $color }
}

# 九宫格 / 百分比 → 工作区坐标（custom 时直接用像素）
function Get-OverlayPlacement {
    param($Cfg, [int]$W, [int]$H)
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($Cfg.anchor -eq 'custom' -and [int]$Cfg.x -ge 0 -and [int]$Cfg.y -ge 0) {
        return @{ x = [int]$Cfg.x; y = [int]$Cfg.y }
    }
    $margin = 24
    $spanX = [math]::Max(0, $wa.Width - $W - 2 * $margin)
    $spanY = [math]::Max(0, $wa.Height - $H - 2 * $margin)
    $px = [math]::Min(1.0, [math]::Max(0.0, [double]$Cfg.px / 100.0))
    $py = [math]::Min(1.0, [math]::Max(0.0, [double]$Cfg.py / 100.0))
    return @{
        x = [int]($wa.Left + $margin + $px * $spanX)
        y = [int]($wa.Top + $margin + $py * $spanY)
    }
}

function Get-OverlayHotkeyVk {
    param($Cfg)
    $key = [string]$Cfg.hotkey.key
    if ($key -match '^F(\d{1,2})$') {
        $n = [int]$Matches[1]
        if ($n -ge 1 -and $n -le 12) { return 0x70 + ($n - 1) }
    }
    if ($key.Length -eq 1) {
        $c = $key.ToUpper()
        if ($c -match '^[A-Z]$') { return [int][char]$c }
        if ($c -match '^[0-9]$') { return [int][char]$c }
    }
    return 0x4D
}

# ---------- 窗体 ----------
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

function Build-OverlayForm {
    $cfg = Get-OverlayCfg
    $style = Get-OverlayStyle $cfg
    $script:OverlayStyle = $style
    $script:OverlayCollapsed = [bool]$cfg.collapsed

    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.Text = 'PerfCapture 浮窗'
    $f.BackColor = [System.Drawing.Color]::FromArgb(26, 28, 34)
    $f.Opacity = [double]$cfg.opacity / 100.0
    $f.MinimizeBox = $false
    $f.MaximizeBox = $false

    $font = New-Object System.Drawing.Font('Microsoft YaHei UI', $style.size)
    $fontSmall = New-Object System.Drawing.Font('Microsoft YaHei UI', $style.small)
    $labelColor = [System.Drawing.Color]::FromArgb(170, 176, 188)
    $rowH = [int]($style.size + 9)

    $controls = @{}
    $rows = @()
    $y = 10
    $defs = @(Get-OverlayRowSet $cfg)
    foreach ($def in $defs) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $def.label
        $lbl.Font = $font
        $lbl.ForeColor = $labelColor
        $lbl.AutoSize = $false
        $lbl.TextAlign = 'MiddleLeft'
        $lbl.SetBounds(12, $y, 40, $rowH)

        $track = New-Object System.Windows.Forms.Panel
        $track.BackColor = [System.Drawing.Color]::FromArgb(52, 56, 66)
        $track.SetBounds(56, $y + [int]($rowH / 3), 118, 6)

        $fill = New-Object System.Windows.Forms.Panel
        $fill.BackColor = [System.Drawing.Color]::FromArgb(134, 114, 186)
        $fill.SetBounds(0, 0, 0, 6)
        $track.Controls.Add($fill)

        $val = New-Object System.Windows.Forms.Label
        $val.Text = '—'
        $val.Font = $fontSmall
        $val.ForeColor = $style.color
        $val.AutoSize = $false
        $val.TextAlign = 'MiddleRight'
        $val.SetBounds(178, $y, 58, $rowH)

        $f.Controls.Add($lbl)
        $f.Controls.Add($track)
        $f.Controls.Add($val)
        $rows += @{ def = $def; label = $lbl; track = $track; fill = $fill; value = $val }
        $y += ($rowH + 12)
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
    $f.add_DoubleClick({ param($sender, $e) Toggle-OverlayCollapsed })

    foreach ($c in @($f.Controls)) {
        $c.add_MouseDown($dragStart)
        $c.add_MouseMove($dragMove)
        $c.add_MouseUp($dragEnd)
        $c.add_DoubleClick({ param($s, $e) Toggle-OverlayCollapsed })
    }

    $script:OverlayForm = $f
    $script:OverlayControls = $rows
    Apply-OverlayLayout

    $pos = Get-OverlayPlacement $cfg $f.Width $f.Height
    $f.Location = New-Object System.Drawing.Point($pos.x, $pos.y)
    return $f
}

function Apply-OverlayLayout {
    $f = $script:OverlayForm
    if (-not $f) { return }
    $cfg = Get-OverlayCfg
    $style = Get-OverlayStyle $cfg
    $rowH = [int]($style.size + 9)
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
        $h = 10 + ($script:OverlayControls.Count * ($rowH + 12)) + 2
        $f.Size = New-Object System.Drawing.Size(250, $h)
        foreach ($row in $script:OverlayControls) {
            $row.label.Visible = $true
            $row.track.Visible = $true
            $row.value.Visible = $true
        }
    }
}

function Set-OverlayVisuals {
    $f = $script:OverlayForm
    if (-not $f) { return }
    $cfg = Get-OverlayCfg
    try { $f.Opacity = [double]$cfg.opacity / 100.0 } catch { }
}

function Rebuild-Overlay {
    $wasVisible = [bool]$script:OverlayVisible
    if ($script:OverlayForm) {
        try { $script:OverlayForm.Hide(); $script:OverlayForm.Dispose() } catch { }
        $script:OverlayForm = $null
    }
    Build-OverlayForm | Out-Null
    if ($wasVisible) {
        $script:OverlayForm.Show()
        $script:OverlayForm.TopMost = $true
    }
}

function Save-OverlayPosition {
    $f = $script:OverlayForm
    if (-not $f) { return }
    try {
        $cfg = Get-OverlayCfg
        $cfg.x = $f.Left
        $cfg.y = $f.Top
        $cfg.anchor = 'custom'
        Save-Config
        # 拖动后必须回传一次：界面上的「坐标 X/Y」和预设（自定义）都靠这条消息回填
        Send-OverlayState
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
            'mem' {
                if ($s -and $null -ne $s.ramUsed -and $null -ne $s.ramTotal -and [double]$s.ramTotal -gt 0) {
                    $pct = [double]$s.ramUsed / [double]$s.ramTotal * 100.0
                    $row.value.Text = ('{0} %' -f [int][math]::Round($pct))
                    $row.fill.Width = [int]([math]::Min(1.0, ($pct / 100.0)) * $row.track.Width)
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
            # 可配热键：修饰键 + 主键，轮询 GetAsyncKeyState（不装键盘钩子）
            if ('PerfOverlayNative' -as [type]) {
                $cfg = Get-OverlayCfg
                $needCtrl = [bool]$cfg.hotkey.ctrl
                $needAlt = [bool]$cfg.hotkey.alt
                $needShift = [bool]$cfg.hotkey.shift
                $vk = Get-OverlayHotkeyVk $cfg
                $ctrl = (([PerfOverlayNative]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0)
                $alt = (([PerfOverlayNative]::GetAsyncKeyState(0x12) -band 0x8000) -ne 0)
                $shift = (([PerfOverlayNative]::GetAsyncKeyState(0x10) -band 0x8000) -ne 0)
                $main = (([PerfOverlayNative]::GetAsyncKeyState($vk) -band 0x8000) -ne 0)
                $down = $main -and ($ctrl -eq $needCtrl) -and ($alt -eq $needAlt) -and ($shift -eq $needShift)
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

function Send-OverlayState {
    $cfg = Get-OverlayCfg
    Send-ToUi @{
        type = 'overlayState'
        visible = [bool]$script:OverlayVisible
        collapsed = [bool]$script:OverlayCollapsed
        overlay = @{
            visible = [bool]$script:OverlayVisible
            x = [int]$cfg.x
            y = [int]$cfg.y
            anchor = [string]$cfg.anchor
            px = [int]$cfg.px
            py = [int]$cfg.py
            opacity = [int]$cfg.opacity
            fontSize = [string]$cfg.fontSize
            fontColor = [string]$cfg.fontColor
            layout = [string]$cfg.layout
            metrics = @($cfg.metrics)
            hotkey = @{
                ctrl = [bool]$cfg.hotkey.ctrl
                alt = [bool]$cfg.hotkey.alt
                shift = [bool]$cfg.hotkey.shift
                key = [string]$cfg.hotkey.key
            }
        }
    }
}

# 前端改设置 → 校验后合并、落盘、即时生效（位置/样式改动会重建窗体）
function Apply-OverlayConfig {
    param($In)
    $cfg = Get-OverlayCfg
    if (-not $In) { Send-OverlayState; return }
    if ($null -ne $In.anchor) {
        $a = [string]$In.anchor
        if ($a -eq 'custom' -or $a -in $script:OverlayAnchors) { $cfg.anchor = $a }
    }
    foreach ($pair in @(@('px', 'px', 0, 100), @('py', 'py', 0, 100), @('x', 'x', -1, 30000), @('y', 'y', -1, 30000), @('opacity', 'opacity', 20, 100))) {
        $src, $dst, $lo, $hi = $pair
        $raw = $In.$src
        if ($null -ne $raw) {
            $n = 0
            if ([int]::TryParse([string]$raw, [ref]$n)) { $cfg.$dst = [int][math]::Min($hi, [math]::Max($lo, $n)) }
        }
    }
    if ($In.fontSize -in @('small', 'normal', 'large')) { $cfg.fontSize = [string]$In.fontSize }
    if ($In.fontColor -in @('white', 'gray', 'green', 'yellow')) { $cfg.fontColor = [string]$In.fontColor }
    if ($In.layout) { $cfg.layout = 'linear' }
    if ($null -ne $In.metrics) {
        $mk = @(@($In.metrics) | ForEach-Object { ([string]$_).ToLower() } | Where-Object { $script:OverlayMetricKeys -contains $_ } | Select-Object -Unique)
        if ($mk.Count) { $cfg.metrics = $mk }
    }
    if ($In.hotkey) {
        $hk = $cfg.hotkey
        if ($null -ne $In.hotkey.ctrl) { $hk.ctrl = [bool]$In.hotkey.ctrl }
        if ($null -ne $In.hotkey.alt) { $hk.alt = [bool]$In.hotkey.alt }
        if ($null -ne $In.hotkey.shift) { $hk.shift = [bool]$In.hotkey.shift }
        if ($In.hotkey.key) {
            $k = ([string]$In.hotkey.key).ToUpper()
            if ($k -match '^[A-Z]$' -or $k -match '^F([1-9]|1[0-2])$') { $hk.key = $k }
        }
        if (-not $hk.ctrl -and -not $hk.alt -and -not $hk.shift) { $hk.ctrl = $true }
    }
    try { Save-Config } catch { }
    # 样式/尺寸变化需要重建才能生效；纯透明度改动直接改属性
    if ($script:OverlayForm) { Rebuild-Overlay }
    Send-OverlayState
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
    $hkText = ''
    if ($cfg.hotkey.ctrl) { $hkText += 'Ctrl+' }
    if ($cfg.hotkey.alt) { $hkText += 'Alt+' }
    if ($cfg.hotkey.shift) { $hkText += 'Shift+' }
    $hkText += [string]$cfg.hotkey.key
    Write-AppLog ('浮窗已显示（' + $hkText + ' 收起/展开；独占全屏下不可见）')
    Send-OverlayState
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
    Send-OverlayState
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
        'overlayConfig' { Apply-OverlayConfig -In $Msg.overlay }
    }
}

# 启动时若上次是开着的，就恢复（位置也一并恢复）
function Restore-OverlayIfNeeded {
    try {
        $cfg = Get-OverlayCfg
        if ($cfg.visible) { Show-Overlay }
    } catch { }
}
