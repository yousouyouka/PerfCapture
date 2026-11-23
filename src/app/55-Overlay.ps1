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
# 拖动锁：开启后鼠标按下不再进入拖动分支（点字、划选都不会挪动窗口）。
# 位置仍可通过设置页的预设 / 滑杆 / 像素坐标改，锁的只是「误拖」这条路径。
$script:OverlayLocked = $false

# ── 浮窗可显示的 16 项（键名与 35-Metrics 采样字段一一对应）──
# group：显示分组（FPS / GPU / CPU / 延迟 / RAM）
# label：堆叠布局里一行的名字（照用户给的样式：GPU 利用率 / FPS 1%L / PCL（av）…）
# field / unit：采样字段与单位；locked：**永远**没有数据源，界面上不给勾选
# dynamic：本机**当前**有没有这条路（按平台能力算），非联想/非管理员时灰掉，但不写死
$script:OverlayItemDefs = @(
    @{ key = 'fps';      group = 'FPS';  label = 'FPS';         unit = '';    field = 'fps' }
    @{ key = 'fpslow';   group = 'FPS';  label = 'FPS 1%L';     unit = '';    field = 'fpsLow1' }
    @{ key = 'gpuutil';  group = 'GPU';  label = 'GPU 利用率';   unit = '%';   field = 'gpu' }
    @{ key = 'gputemp';  group = 'GPU';  label = 'GPU 温度';     unit = '°C';  field = 'gpuTemp' }
    @{ key = 'gpuclock'; group = 'GPU';  label = 'GPU 频率';     unit = 'MHz'; field = 'gpuClock' }
    @{ key = 'gpupower'; group = 'GPU';  label = 'GPU 功率';     unit = 'W';   field = 'gpuPower' }
    @{ key = 'gpufan';   group = 'GPU';  label = 'GPU 风扇速度'; unit = '%';   field = 'gpuFan' }
    @{ key = 'vramclk';  group = 'GPU';  label = 'VRAM 频率';    unit = 'MHz'; field = 'gpuMemClock' }
    @{ key = 'gpuvolt';  group = 'GPU';  label = 'GPU 电压';     unit = 'V';   locked = $true }
    @{ key = 'cpuutil';  group = 'CPU';  label = 'CPU 利用率';   unit = '%';   field = 'cpu' }
    @{ key = 'cpuclock'; group = 'CPU';  label = 'CPU 频率';     unit = 'MHz'; field = 'cpuMhz' }
    @{ key = 'cpupower'; group = 'CPU';  label = 'CPU 功率';     unit = 'W';   field = 'cpuPower' }
    @{ key = 'cputemp';  group = 'CPU';  label = 'CPU 温度';     unit = '°C';  field = 'cpuTemp'; dynamic = 'temp' }
    @{ key = 'rlat';     group = '延迟'; label = 'RLAT';         unit = 'ms';  field = 'rlat' }
    @{ key = 'pcl';      group = '延迟'; label = 'PCL（av）';    unit = 'ms';  field = 'pcl' }
    @{ key = 'ram';      group = 'RAM';  label = 'RAM';          unit = '%';   field = '__ram' }
)

$script:OverlayItemKeys = @($script:OverlayItemDefs | ForEach-Object { $_.key })
# 本机拿不到的项：界面上灰掉、不可勾选，也不写进配置。
# 2.1.11 起 cputemp 不再写死——2.1.10 已接入联想固件通道，写死会把已经有数的机器也锁上。
# 静态 locked 管「永远没有」；dynamic 管「这台机器现在有没有」，每次现算。
function Get-OverlayLockedKeys {
    $keys = @($script:OverlayItemDefs | Where-Object { $_.locked } | ForEach-Object { $_.key })
    foreach ($d in $script:OverlayItemDefs) {
        if (-not $d.dynamic) { continue }
        $ok = $false
        try { $ok = [bool](Test-PlatformCapability $d.dynamic) } catch { $ok = $false }
        if (-not $ok) { $keys += $d.key }
    }
    return $keys
}
$script:OverlayLockedKeys = @(Get-OverlayLockedKeys)
$script:OverlaySelectableKeys = @($script:OverlayItemDefs | Where-Object { -not $_.locked -and $script:OverlayLockedKeys -notcontains $_.key } | ForEach-Object { $_.key })
$script:OverlayGroupOrder = @('FPS', 'GPU', 'CPU', '延迟', 'RAM')

# 首次开启时的默认显示项（想只看 FPS 就在设置里全关掉、只留一项）
$script:OverlayDefaultItems = @('fps', 'gpuutil', 'gputemp', 'gpupower', 'ram')

# 只显示用户勾选的项（locked 项一律剔除）；空集合兜底 FPS，避免浮窗变空白
function Get-OverlayItemSet {
    param($Cfg)
    $keys = @()
    if ($null -ne $Cfg.items) { $keys = @($Cfg.items) }
    if (-not $keys.Count) { $keys = $script:OverlayDefaultItems }
    $locked = @(Get-OverlayLockedKeys)
    $rows = @($script:OverlayItemDefs | Where-Object { $keys -contains $_.key -and $locked -notcontains $_.key })
    if (-not $rows.Count) { $rows = @($script:OverlayItemDefs[0]) }
    return $rows
}

$script:OverlayAnchors = @('tl', 't', 'tr', 'l', 'c', 'r', 'bl', 'b', 'br')

# ---------- 配置 ----------
function Get-OverlayCfg {
    if (-not $script:Cfg.overlay) { $script:Cfg.overlay = @{} }
    $o = $script:Cfg.overlay
    $def = [ordered]@{
        visible = $false; x = -1; y = -1; opacity = 0; collapsed = $false
        anchor = 'tr'; px = 100; py = 0
        fontSize = 'normal'; fontColor = 'white'; layout = 'linear'; locked = $false
    }
    foreach ($k in $def.Keys) { if ($null -eq $o.$k) { $o.$k = $def[$k] } }
    if (-not $o.hotkey) { $o.hotkey = @{ ctrl = $true; alt = $true; shift = $false; key = 'M' } }
    if (-not $o.hotkey.key) { $o.hotkey.key = 'M' }

    # 显示项：新键 items（16 项逐项勾）。老配置只有 metrics（四个族）→ 一次性迁移，之后不再读 metrics
    $ik = @()
    if ($null -ne $o.items) {
        $ik = @(@($o.items) | ForEach-Object { ([string]$_).ToLower() } | Where-Object { $script:OverlaySelectableKeys -contains $_ } | Select-Object -Unique)
    }
    if (-not $ik.Count -and $null -ne $o.metrics) {
        $map = @{ fps = @('fps', 'fpslow'); cpu = @('cpuutil', 'cpuclock', 'cpupower'); gpu = @('gpuutil', 'gputemp', 'gpupower'); mem = @('ram') }
        foreach ($fam in @($o.metrics)) {
            $kk = ([string]$fam).ToLower()
            if ($map.ContainsKey($kk)) { $ik += $map[$kk] }
        }
        $ik = @($ik | Select-Object -Unique)
        if ($ik.Count) { Write-AppLog '浮窗配置迁移：旧的四族 metrics → 新的逐项 items' }
    }
    # 老配置里可能有已下线的项（比如黑字时代的组合），统一按可选清单收口
    $ik = @($ik | Where-Object { $script:OverlaySelectableKeys -contains $_ })
    if (-not $ik.Count) { $ik = $script:OverlayDefaultItems }
    $o.items = $ik

    # 老配置里 opacity 是 0..1，迁移到百分比；现在允许 0（背景完全透明，只有字浮在画面上）
    $op = 0.0
    try { $op = [double]$o.opacity } catch { }
    if ($op -gt 0 -and $op -le 1) { $op = $op * 100 }
    $o.opacity = [int][math]::Min(100, [math]::Max(0, [math]::Round($op)))
    if ($o.anchor -notin $script:OverlayAnchors -and $o.anchor -ne 'custom') { $o.anchor = 'tr' }
    if ($o.fontSize -notin @('small', 'normal', 'large')) { $o.fontSize = 'normal' }
    if ($o.fontColor -notin @('white', 'green', 'red', 'blue')) { $o.fontColor = 'white' }
    if ($o.layout -notin @('linear', 'stacked')) { $o.layout = 'linear' }
    # 拖动锁：JSON 里可能是 true/false/"true"/1，统一收成布尔；缺省视为不锁。
    $lk = $o.locked
    $o.locked = if ($lk -is [bool]) { $lk } elseif ($null -eq $lk) { $false } else { ([string]$lk) -match '^(?i)(true|1|yes|on)$' }
    return $o
}

function Get-OverlayStyle {
    param($Cfg)
    $size = switch ($Cfg.fontSize) { 'small' { 8 } 'large' { 12 } default { 10 } }
    # 四种字色（黑字已删：透明底上看不见，配浅底又和其他颜色行为不一致）
    $pal = @{
        white = @(235, 238, 245)
        green = @(150, 226, 170)
        red   = @(242, 138, 138)
        blue  = @(150, 195, 245)
    }
    $c = if ($pal.ContainsKey([string]$Cfg.fontColor)) { $pal[[string]$Cfg.fontColor] } else { $pal['white'] }
    return @{
        size  = $size
        color = [System.Drawing.Color]::FromArgb($c[0], $c[1], $c[2])
        back  = [System.Drawing.Color]::FromArgb(26, 28, 34)
        # TransparencyKey 用一个绝不会出现在文字里的颜色，避免把字也抠掉
        key   = [System.Drawing.Color]::FromArgb(1, 2, 3)
    }
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
    $script:OverlayLocked = [bool]$cfg.locked

    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.Text = 'PerfCapture 浮窗'
    $f.BackColor = $style.back
    $f.MinimizeBox = $false
    $f.MaximizeBox = $false
    $f.Padding = New-Object System.Windows.Forms.Padding(0)

    $font = New-Object System.Drawing.Font('Microsoft YaHei UI', $style.size)

    # 按项生成：每项一对「名字 + 数值」标签。
    #   堆叠：一项一行，名字用完整名（GPU 利用率 / FPS 1%L / PCL（av））
    #   线性：同一组的项并到一行，组名只出现一次（FPS / GPU / CPU / 延迟 / RAM），后面只跟值
    # 两种布局共用同一批标签，切换时只改文本与坐标（见 Apply-OverlayLayout）。
    $rows = @()
    $items = @(Get-OverlayItemSet $cfg)
    $seenGroups = @{}
    foreach ($def in $items) {
        $isGroupHead = -not $seenGroups.ContainsKey([string]$def.group)
        $seenGroups[[string]$def.group] = $true

        $name = New-Object System.Windows.Forms.Label
        $name.Text = [string]$def.label
        $name.Font = $font
        $name.ForeColor = $style.color
        $name.BackColor = [System.Drawing.Color]::Transparent
        $name.AutoSize = $false
        $name.TextAlign = 'MiddleLeft'

        $val = New-Object System.Windows.Forms.Label
        $val.Text = 'N/A'
        $val.Font = $font
        $val.ForeColor = $style.color
        $val.BackColor = [System.Drawing.Color]::Transparent
        $val.AutoSize = $false
        $val.TextAlign = 'MiddleRight'

        $f.Controls.Add($name)
        $f.Controls.Add($val)
        $rows += @{ def = $def; group = [string]$def.group; head = $isGroupHead; name = $name; value = $val }
    }

    # 拖动 / 双击收起（挂到窗体与每个标签上，否则点在字上拖不动）
    # 锁定后 MouseDown 直接返回：既不置 dragging，也不记录偏移，鼠标怎么划窗口都不动。
    # 双击收起仍然可用——那是显式操作，不会因为鼠标划过就误触。
    $dragStart = {
        param($sender, $e)
        if ($script:OverlayLocked) { return }
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $script:OverlayDragging = $true
            $script:OverlayDragOffset = $e.Location
            if ($sender -isnot [System.Windows.Forms.Form]) {
                $script:OverlayDragOffset = New-Object System.Drawing.Point(
                    ($e.X + $sender.Left), ($e.Y + $sender.Top))
            }
        }
    }
    $dragMove = {
        param($sender, $e)
        if ($script:OverlayLocked) { return }
        if ($script:OverlayDragging -and $script:OverlayForm) {
            $pt = [System.Windows.Forms.Cursor]::Position
            $script:OverlayForm.Location = New-Object System.Drawing.Point(
                ($pt.X - $script:OverlayDragOffset.X), ($pt.Y - $script:OverlayDragOffset.Y))
        }
    }
    $dragEnd = {
        param($sender, $e)
        if ($script:OverlayLocked) { $script:OverlayDragging = $false; return }
        if ($script:OverlayDragging) {
            $script:OverlayDragging = $false
            Save-OverlayPosition
        }
    }
    $f.add_MouseDown($dragStart)
    $f.add_MouseMove($dragMove)
    $f.add_MouseUp($dragEnd)
    $f.add_DoubleClick({ param($sender, $e) Toggle-OverlayCollapsed })

    foreach ($r in $rows) {
        foreach ($c in @($r.name, $r.value)) {
            $c.add_MouseDown($dragStart)
            $c.add_MouseMove($dragMove)
            $c.add_MouseUp($dragEnd)
            $c.add_DoubleClick({ param($s, $e) Toggle-OverlayCollapsed })
        }
    }

    $script:OverlayForm = $f
    $script:OverlayControls = $rows
    Set-OverlayVisuals
    Apply-OverlayLayout

    $pos = Get-OverlayPlacement $cfg $f.Width $f.Height
    $f.Location = New-Object System.Drawing.Point($pos.x, $pos.y)
    return $f
}

# 两种布局共用同一批标签，只是摆放方式不同：
#   stacked（堆叠，默认）= 一项一行，名字在左、数值在右
#   linear（线性）      = 一整行横着排，项与项之间空开；超宽时窗口自己变宽（不换行）
function Apply-OverlayLayout {
    $f = $script:OverlayForm
    if (-not $f) { return }
    $cfg = Get-OverlayCfg
    $rows = @($script:OverlayControls)
    if (-not $rows.Count) { return }
    $pad = 10
    $meas = [System.Windows.Forms.TextRenderer]

    if ($script:OverlayCollapsed) {
        foreach ($r in $rows) { $r.name.Visible = $false; $r.value.Visible = $false }
        $first = $rows[0]
        $first.value.Visible = $true
        $sz = $meas::MeasureText([string]$first.value.Text, $first.value.Font)
        $w = [int]($sz.Width + $pad * 2)
        $h = [int]($sz.Height + $pad)
        $first.value.SetBounds($pad, [int]($pad / 2), $sz.Width, $sz.Height)
        $f.Size = New-Object System.Drawing.Size($w, $h)
        return
    }

    # 两种布局共用的控件，只是文本与坐标不同
    #   堆叠：一行一项，名字用完整名，值右对齐
    #   线性：同组并到一行——组名只出现在组首（组间加 |），组内只排值
    if ($cfg.layout -eq 'linear') {
        $gap = 7
        $groupGap = 12
        $x = $pad
        $maxH = 0
        $firstGroup = $true
        foreach ($r in $rows) {
            if ($r.head) {
                if (-not $firstGroup) { $x += $groupGap }
                $r.name.Text = $(if ($firstGroup) { [string]$r.group } else { '| ' + [string]$r.group })
                $r.name.Visible = $true
                $s1 = $meas::MeasureText([string]$r.name.Text, $r.name.Font)
                $r.name.SetBounds($x, $pad, $s1.Width, $s1.Height)
                $x += $s1.Width + $gap
                if ($s1.Height -gt $maxH) { $maxH = $s1.Height }
                $firstGroup = $false
            } else {
                # 组内其余项：不显示名字（值靠顺序对应）
                $r.name.Text = ''
                $r.name.Visible = $false
                $r.name.SetBounds($x, $pad, 0, 1)
            }
            $r.value.Visible = $true
            $s2 = $meas::MeasureText([string]$r.value.Text, $r.value.Font)
            $r.value.SetBounds($x, $pad, $s2.Width, $s2.Height)
            $x += $s2.Width + $gap
            if ($s2.Height -gt $maxH) { $maxH = $s2.Height }
        }
        $w = [int]($x - $gap + $pad)
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        if ($w -gt [int]($wa.Width * 0.95)) { $w = [int]($wa.Width * 0.95) }
        $f.Size = New-Object System.Drawing.Size($w, [int]($maxH + $pad * 2))
    } else {
        $nameW = 0
        $valW = 0
        $rowH = 0
        foreach ($r in $rows) {
            $r.name.Text = [string]$r.def.label
            $r.name.Visible = $true
            $r.value.Visible = $true
            $s1 = $meas::MeasureText([string]$r.name.Text, $r.name.Font)
            $s2 = $meas::MeasureText([string]$r.value.Text, $r.value.Font)
            if ($s1.Width -gt $nameW) { $nameW = $s1.Width }
            if ($s2.Width -gt $valW) { $valW = $s2.Width }
            if ($s1.Height -gt $rowH) { $rowH = $s1.Height }
        }
        $rowH = [int]($rowH + 6)
        $y = $pad
        foreach ($r in $rows) {
            $r.name.SetBounds($pad, $y, $nameW, $rowH)
            $r.value.SetBounds($pad + $nameW + 14, $y, $valW, $rowH)
            $y += $rowH
        }
        $f.Size = New-Object System.Drawing.Size([int]($pad * 2 + $nameW + 14 + $valW), [int]($y + $pad))
    }
}

# 背景不透明度：
#   0   = 背景完全透明（TransparencyKey 抠掉底色），文字仍是 100% 不透明 —— 这是默认值
#   >0  = 整窗按百分比半透明（WinForms 的 Opacity 只能整窗，文字会跟着变淡）
function Set-OverlayVisuals {
    $f = $script:OverlayForm
    if (-not $f) { return }
    $cfg = Get-OverlayCfg
    $style = Get-OverlayStyle $cfg
    $op = [int]$cfg.opacity
    try {
        if ($op -le 0) {
            $f.Opacity = 1.0
            $f.BackColor = $style.key
            $f.TransparencyKey = $style.key
        } else {
            $f.TransparencyKey = [System.Drawing.Color]::Empty
            $f.BackColor = $style.back
            $f.Opacity = [double]$op / 100.0
        }
    } catch { }
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

# 单项取值：只返回「数值 + 单位」（短名由调用方拼），取不到返回 $null
function Format-OverlayItemValue {
    param($Def, $S)
    if ($Def.locked) { return $null }
    if (-not $S) { return $null }
    $raw = $null
    if ($Def.field -eq '__ram') {
        if ($null -ne $S.ramUsed -and $null -ne $S.ramTotal -and [double]$S.ramTotal -gt 0) {
            $raw = [double]$S.ramUsed / [double]$S.ramTotal * 100.0
        }
    } else {
        $raw = $S.($Def.field)
    }
    if ($null -eq $raw) {
        # 1%L 冷启动：已经收到帧、只是样本还不够（约 6 秒窗口 / 20 帧）。
        # 显示「…」表示「再等一下」，与「拿不到」的 N/A 区分开——两者不是一回事。
        if ($Def.key -eq 'fpslow' -and [string]$S.fpsLow1State -eq 'warming') { return '…' }
        return $null
    }
    $v = [double]$raw
    $txt = switch ($Def.key) {
        'fps'      { '{0:0.0}' -f $v }
        'fpslow'   { '{0:0.0}' -f $v }
        'rlat'     { '{0:0.0}' -f $v }
        'pcl'      { '{0:0.0}' -f $v }
        'gpuutil'  { '{0:0}' -f $v }
        'gputemp'  { '{0:0}' -f $v }
        'gpuclock' { '{0:0}' -f $v }
        'gpupower' { '{0:0.0}' -f $v }
        'gpufan'   { '{0:0}' -f $v }
        'vramclk'  { '{0:0}' -f $v }
        'cpuutil'  { '{0:0}' -f $v }
        'cpuclock' { '{0:0}' -f $v }
        'cpupower' { '{0:0.0}' -f $v }
        'cputemp'  { '{0:0}' -f $v }
        'ram'      { '{0:0}' -f $v }
        default    { '{0:0.0}' -f $v }
    }
    if ($Def.unit) { $txt += ' ' + $Def.unit }
    return $txt
}

# 一项一个数值：拿不到就写 N/A（绝不写 0，也不留上一次的旧值）
function Update-OverlayReadout {
    $f = $script:OverlayForm
    if (-not $f -or -not $script:OverlayControls) { return }
    $s = $null
    if ($script:MetricsSamples -and $script:MetricsSamples.Count -gt 0) {
        $s = $script:MetricsSamples[$script:MetricsSamples.Count - 1]
    }
    $changed = $false
    foreach ($row in $script:OverlayControls) {
        $v = Format-OverlayItemValue $row.def $s
        $txt = if ($null -ne $v) { $v } else { 'N/A' }
        if ($row.value.Text -ne $txt) {
            $row.value.Text = $txt
            $changed = $true
        }
    }
    # 数值宽度会变（57.3 → 100.4），重新摆一次位置，避免右对齐的数字抖
    if ($changed) { Apply-OverlayLayout }
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
            locked = [bool]$cfg.locked
            items = @($cfg.items)
            itemKeys = @($script:OverlayItemKeys)
            itemLocked = @(Get-OverlayLockedKeys)
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
    foreach ($pair in @(@('px', 'px', 0, 100), @('py', 'py', 0, 100), @('x', 'x', -1, 30000), @('y', 'y', -1, 30000), @('opacity', 'opacity', 0, 100))) {
        $src, $dst, $lo, $hi = $pair
        $raw = $In.$src
        if ($null -ne $raw) {
            $n = 0
            if ([int]::TryParse([string]$raw, [ref]$n)) { $cfg.$dst = [int][math]::Min($hi, [math]::Max($lo, $n)) }
        }
    }
    if ($In.fontSize -in @('small', 'normal', 'large')) { $cfg.fontSize = [string]$In.fontSize }
    if ($In.fontColor -in @('white', 'green', 'red', 'blue')) { $cfg.fontColor = [string]$In.fontColor }
    if ($In.layout -in @('linear', 'stacked')) { $cfg.layout = [string]$In.layout }
    # 拖动锁：只接受明确的布尔语义，非法值保持原样（不多做猜测）；改了要重建窗体让处理器读新值。
    if ($null -ne $In.locked) {
        $raw = $In.locked
        if ($raw -is [bool]) { $cfg.locked = $raw }
        elseif (([string]$raw) -match '^(?i)(true|1|yes|on|false|0|no|off)$') { $cfg.locked = ([string]$raw) -match '^(?i)(true|1|yes|on)$' }
    }
    if ($null -ne $In.items) {
        $ik = @(@($In.items) | ForEach-Object { ([string]$_).ToLower() } | Where-Object { $script:OverlaySelectableKeys -contains $_ } | Select-Object -Unique)
        # 允许只留一项，但**不允许全空**：全空时浮窗会变成一块空白，比不显示更糟
        if ($ik.Count) { $cfg.items = $ik }
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
