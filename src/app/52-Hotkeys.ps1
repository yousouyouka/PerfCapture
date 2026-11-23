# 全局热键（2.1.16 / F3-1）
#
# 目的：游戏里不用切回工具就能开始 / 停止采集。
#
# 约束与做法：
#   - 只用 RegisterHotKey，不装钩子、不注入，与「零注入」一致。
#   - 命中热键后**不直接跑采集**，而是给前端发一条 `hotkey` 消息，让前端走「点开始按钮」同一条路径：
#     目标进程、采集项、秒数都以界面当前状态为准，避免宿主与界面各存一份参数后走岔。
#   - 注册失败（组合已被别的程序占用）必须明确告知，不能静默失效。
#   - 关闭开关或退出时注销，不留系统级残留。

$script:HotkeyIdStart = 0x5043   # 'PC'
$script:HotkeyIdStop = 0x5044
$script:HotkeyFilter = $null
$script:HotkeyRegistered = @()

$hotkeyCs = @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class PerfHotkeyFilter : IMessageFilter
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private IntPtr _hwnd;
    public event EventHandler<int> Pressed;

    public PerfHotkeyFilter(IntPtr hwnd) { _hwnd = hwnd; }

    public bool Register(int id, uint modifiers, uint vk)
    {
        return RegisterHotKey(_hwnd, id, modifiers, vk);
    }

    public void Unregister(int id)
    {
        UnregisterHotKey(_hwnd, id);
    }

    // WM_HOTKEY = 0x0312。返回 true 表示已消费，不再往下传。
    public bool PreFilterMessage(ref Message m)
    {
        if (m.Msg == 0x0312)
        {
            int id = m.WParam.ToInt32();
            EventHandler<int> h = Pressed;
            if (h != null) h(this, id);
            return true;
        }
        return false;
    }
}
'@

function Get-HotkeyModifiers($cfg) {
    # MOD_ALT=1 MOD_CONTROL=2 MOD_SHIFT=4；MOD_NOREPEAT 防止长按连续触发
    $m = 0x4000
    if ($cfg.ctrl) { $m = $m -bor 0x0002 }
    if ($cfg.alt) { $m = $m -bor 0x0001 }
    if ($cfg.shift) { $m = $m -bor 0x0004 }
    return [uint32]$m
}

function Get-HotkeyVk([string]$Key) {
    switch (([string]$Key).ToUpperInvariant()) {
        'F1'  { return [uint32]0x70 }
        'F2'  { return [uint32]0x71 }
        'F3'  { return [uint32]0x72 }
        'F4'  { return [uint32]0x73 }
        'F5'  { return [uint32]0x74 }
        'F6'  { return [uint32]0x75 }
        'F7'  { return [uint32]0x76 }
        'F8'  { return [uint32]0x77 }
        'F9'  { return [uint32]0x78 }
        'F10' { return [uint32]0x79 }
        'F11' { return [uint32]0x7A }
        'F12' { return [uint32]0x7B }
        default { return [uint32]0 }
    }
}

function Get-HotkeyLabel($cfg) {
    $parts = @()
    if ($cfg.ctrl) { $parts += 'Ctrl' }
    if ($cfg.alt) { $parts += 'Alt' }
    if ($cfg.shift) { $parts += 'Shift' }
    $parts += ([string]$cfg.key).ToUpperInvariant()
    return ($parts -join '+')
}

# 注销已注册的热键（关开关、改配置、退出时调用）
function Unregister-PerfHotkeys {
    if ($null -eq $script:HotkeyFilter) { return }
    foreach ($id in $script:HotkeyRegistered) {
        try { $script:HotkeyFilter.Unregister($id) } catch { }
    }
    $script:HotkeyRegistered = @()
    Write-AppLog '全局热键已注销'
}

# 按当前配置注册；返回是否全部成功，失败原因写日志并回传前端
function Register-PerfHotkeys {
    $hk = $script:Cfg.hotkeys
    Unregister-PerfHotkeys
    if ($null -eq $hk -or -not $hk.enabled) { return $false }

    if ($null -eq $script:HotkeyFilter) {
        if (-not ('PerfHotkeyFilter' -as [type])) { Add-Type -TypeDefinition $hotkeyCs -Language CSharp }
        $script:HotkeyFilter = New-Object PerfHotkeyFilter($form.Handle)
        # 回调里不能直接跑采集（会在消息泵里递归）：交回 UI，由前端走「点开始/停止」同一条路径
        $script:HotkeyFilter.add_Pressed({
            param($sender, $id)
            try {
                if ($id -eq $script:HotkeyIdStart) { Send-ToUi @{ type = 'hotkey'; action = 'start' } }
                elseif ($id -eq $script:HotkeyIdStop) { Send-ToUi @{ type = 'hotkey'; action = 'stop' } }
            } catch { Write-AppLog ('热键回调失败: ' + $_.Exception.Message) 'WARN' }
        })
        [System.Windows.Forms.Application]::AddMessageFilter($script:HotkeyFilter)
    }

    $okAll = $true
    $fail = @()
    foreach ($spec in @(
            @{ id = $script:HotkeyIdStart; cfg = $hk.start; name = '开始' },
            @{ id = $script:HotkeyIdStop; cfg = $hk.stop; name = '停止' }
        )) {
        $vk = Get-HotkeyVk $spec.cfg.key
        if ($vk -eq 0) { $okAll = $false; $fail += ($spec.name + '：键名无效'); continue }
        $mods = Get-HotkeyModifiers $spec.cfg
        $ok = $false
        try { $ok = $script:HotkeyFilter.Register([int]$spec.id, $mods, $vk) } catch { $ok = $false }
        if ($ok) { $script:HotkeyRegistered += [int]$spec.id }
        else { $okAll = $false; $fail += ($spec.name + '：' + (Get-HotkeyLabel $spec.cfg) + ' 已被其它程序占用') }
    }

    if ($okAll) {
        Write-AppLog ('全局热键: 开始 ' + (Get-HotkeyLabel $hk.start) + ' / 停止 ' + (Get-HotkeyLabel $hk.stop))
    } else {
        Write-AppLog ('全局热键注册失败 · ' + ($fail -join '；')) 'WARN'
        Send-Log ('  ! 热键不可用：' + ($fail -join '；')) 'ln-warn'
    }
    Send-ToUi @{
        type  = 'hotkeys'
        ok    = $okAll
        start = (Get-HotkeyLabel $hk.start)
        stop  = (Get-HotkeyLabel $hk.stop)
        fail  = ($fail -join '；')
    }
    return $okAll
}

function Invoke-HotkeyCommand($msg) {
    switch ([string]$msg.cmd) {
        'setHotkeys' {
            # 只接受结构完整的配置；缺字段保持原值，不做「部分覆盖」
            if ($null -ne $msg.enabled) { $script:Cfg.hotkeys.enabled = [bool]$msg.enabled }
            if ($null -ne $msg.start) { $script:Cfg.hotkeys.start = @{ ctrl = [bool]$msg.start.ctrl; alt = [bool]$msg.start.alt; shift = [bool]$msg.start.shift; key = [string]$msg.start.key } }
            if ($null -ne $msg.stop) { $script:Cfg.hotkeys.stop = @{ ctrl = [bool]$msg.stop.ctrl; alt = [bool]$msg.stop.alt; shift = [bool]$msg.stop.shift; key = [string]$msg.stop.key } }
            Save-Config
            [void](Register-PerfHotkeys)
        }
        'getHotkeys' {
            $hk = $script:Cfg.hotkeys
            Send-ToUi @{ type = 'hotkeys'; ok = $true; enabled = [bool]$hk.enabled
                start = (Get-HotkeyLabel $hk.start); stop = (Get-HotkeyLabel $hk.stop); fail = '' }
        }
        default { }
    }
}

# ---------- 采集结束的任务栏提醒（2.1.16 / F3-3）----------
# 采集期间窗口可能被最小化或压在游戏下面，结束时闪任务栏比抢焦点更礼貌：
# 只闪几下提示「跑完了」，是否切回来由用户决定。
$flashCs = @'
using System;
using System.Runtime.InteropServices;

public class PcTaskbarFlash
{
    [StructLayout(LayoutKind.Sequential)]
    public struct FLASHWINFO
    {
        public uint cbSize;
        public IntPtr hwnd;
        public uint dwFlags;
        public uint uCount;
        public uint dwTimeout;
    }

    [DllImport("user32.dll")]
    public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

    public static bool Flash(IntPtr hwnd, uint count)
    {
        FLASHWINFO f = new FLASHWINFO();
        f.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
        f.hwnd = hwnd;
        f.dwFlags = 0x00000002;   // FLASHW_TRAY
        f.uCount = count;
        f.dwTimeout = 0;
        return FlashWindowEx(ref f);
    }
}
'@

function Flash-PerfTaskbar([int]$Count = 3) {
    try {
        if (-not ('PcTaskbarFlash' -as [type])) { Add-Type -TypeDefinition $flashCs -Language CSharp }
        [void][PcTaskbarFlash]::Flash($form.Handle, [uint32]$Count)
    } catch { Write-AppLog ('任务栏提醒失败: ' + $_.Exception.Message) 'WARN' }
}
