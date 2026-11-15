# 窗口与 WebView2 宿主

# ---------- 任务栏身份 ----------
# 宿主进程是 powershell.exe，不声明身份的话任务栏会把窗口归到 PowerShell 名下、
# 用 PowerShell 的图标。设置显式 AppUserModelID 后本窗口独立分组，图标取窗口图标。
$shellExCode = @'
using System;
using System.Runtime.InteropServices;
public class Shell32Ex {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
}
'@
try {
    if (-not ('Shell32Ex' -as [type])) { Add-Type -TypeDefinition $shellExCode }
    [void][Shell32Ex]::SetCurrentProcessExplicitAppUserModelID('PerfCapture.Main')
} catch {
    Write-AppLog ('设置 AppUserModelID 失败: ' + $_.Exception.Message) 'WARN'
}

# ---------- 窗体 ----------
$form = New-Object System.Windows.Forms.Form
$script:MainForm = $form
$form.Text = 'PerfCapture'
$form.AutoScaleMode = 'None'
$form.StartPosition = 'CenterScreen'
# 配置里的尺寸按「逻辑像素（96 DPI 基准）」存，这里换算成当前缩放下的物理像素
$logicalW = [int]$script:Cfg.windowW
$logicalH = [int]$script:Cfg.windowH
if ($logicalW -lt 980) { $logicalW = 1180 }
if ($logicalH -lt 640) { $logicalH = 780 }
$form.MinimumSize = New-Object System.Drawing.Size([int](980 * $script:DpiScale), [int](640 * $script:DpiScale))
$form.ClientSize = New-Object System.Drawing.Size([int]($logicalW * $script:DpiScale), [int]($logicalH * $script:DpiScale))
$form.BackColor = [System.Drawing.Color]::FromArgb(233, 232, 239)
$form.KeyPreview = $false
try {
    $pi = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
    $pi.SetValue($form, $true, $null)
} catch { }

# 本窗口永不置顶（历史问题：调试脚本曾把 TopMost 打在窗口上，导致压在最上层且拖不动）
$form.TopMost = $false

# 图标：优先多尺寸 .ico（标题栏 / 任务栏 / Alt+Tab 各挑最合适的像素尺寸）。
# 从 PNG 现转 HICON 只有单一尺寸，系统会缩放，且 Bitmap 被 GC 后句柄失效会退回默认图标。
$icoPath = Join-Path $script:AssetDir 'app-icon.ico'
$pngPath = Join-Path $script:AssetDir 'app-icon.png'
$script:IconBmp = $null
$script:IconHicon = [IntPtr]::Zero
$iconReady = $false
if (Test-Path $icoPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($icoPath); $iconReady = $true } catch { }
}
if (-not $iconReady -and (Test-Path $pngPath)) {
    try {
        # 用脚本级变量持有引用，保证 HICON 在窗口生命周期内一直有效
        $script:IconBmp = [System.Drawing.Bitmap]::FromFile($pngPath)
        $script:IconHicon = $script:IconBmp.GetHicon()
        $form.Icon = [System.Drawing.Icon]::FromHandle($script:IconHicon)
    } catch { }
}


# 深色标题栏（Windows 10 1809+）
$dwmCode = @'
using System;
using System.Runtime.InteropServices;
public class DwmApi {
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
'@
if (-not ('DwmApi' -as [type])) { try { Add-Type -TypeDefinition $dwmCode } catch { } }
function Set-TitleBarDark([bool]$dark) {
    if (-not ('DwmApi' -as [type])) { return }
    try {
        $v = if ($dark) { 1 } else { 0 }
        [void][DwmApi]::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4)
    } catch { }
}

# ---------- WebView2 ----------
$wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
$wv.Dock = 'Fill'
$wv.DefaultBackgroundColor = [System.Drawing.Color]::FromArgb(233, 232, 239)
$form.Controls.Add($wv)

$script:Core = $null
$script:Job = $null
$script:T0 = $null
$script:TotalSec = 0
$script:LogIdx = 0
$script:Before = @()
$script:LastJson = $null
$script:LastRun = ''

$form.Add_Shown({
    try {
        $udfRoot = Join-Path $env:LOCALAPPDATA 'PerfCapture\WebView2'
        if (-not (Test-Path $udfRoot)) { New-Item -ItemType Directory -Path $udfRoot -Force | Out-Null }
        # 内置固定版运行时优先（打包后不依赖系统装没装 WebView2）；
        # 目录缺失/损坏则回退系统 Evergreen —— 保证"内置坏了也还能起来"。
        $browserDir = Join-Path $script:Root 'runtime\webview2'
        if (Test-Path (Join-Path $browserDir 'msedgewebview2.exe')) {
            # 关键：固定版必须用独立的 user data folder。
            # 和系统 Evergreen 共用同一个 UDF 时，EnsureCoreWebView2Async 会立即失败。
            $udf = Join-Path $udfRoot 'fixed'
            Write-AppLog ('WebView2 运行时: 内置 ' + $browserDir + ' / UDF=' + $udf)
        } else {
            $udf = $udfRoot
            $browserDir = $null
            Write-AppLog ('WebView2 运行时: 内置目录缺失，回退系统 Evergreen / UDF=' + $udf) 'WARN'
        }
        if (-not (Test-Path $udf)) { New-Item -ItemType Directory -Path $udf -Force | Out-Null }

        $envTask = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync($browserDir, $udf, $null)
        $guard = 0
        while (-not $envTask.IsCompleted -and $guard -lt 800) {
            [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 25; $guard++
        }
        if (-not $envTask.IsCompleted) { throw 'WebView2 环境初始化超时（20 秒）。' }
        if ($envTask.IsFaulted) {
            $why = $envTask.Exception.GetBaseException().Message
            throw ('WebView2 环境初始化失败: ' + $why)
        }
        $coreEnv = $envTask.Result
        Write-AppLog ('WebView2 浏览器版本: ' + $coreEnv.BrowserVersionString)
        $script:WV2Version = [string]$coreEnv.BrowserVersionString

        $task = $wv.EnsureCoreWebView2Async($coreEnv)
        $guard = 0
        while (-not $task.IsCompleted -and $guard -lt 800) {
            [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 25; $guard++
        }
        # 把真实异常带出来，否则只剩"控件初始化失败"这种没法排查的话
        if ($task.IsFaulted) {
            $why = $task.Exception.GetBaseException().Message
            throw ('WebView2 控件初始化失败: ' + $why)
        }
        if ($null -eq $wv.CoreWebView2) { throw 'WebView2 控件初始化失败：CoreWebView2 为空且未返回异常。' }

        $script:Core = $wv.CoreWebView2
        $s = $script:Core.Settings
        $s.AreDefaultContextMenusEnabled = $false
        $s.AreDevToolsEnabled = $false
        $s.IsStatusBarEnabled = $false
        $s.IsZoomControlEnabled = $false
        $s.IsSwipeNavigationEnabled = $false
        $s.AreBrowserAcceleratorKeysEnabled = $false

        # 显式补一次大/小图标：部分系统上 Form.Icon 只落到小图标，任务栏仍显示默认图
        try {
            $hIcon = $form.Icon.Handle
            if ($hIcon -ne [IntPtr]::Zero) {
                [void][Shell32Ex]::SendMessageW($form.Handle, 0x0080, [IntPtr]1, $hIcon)   # WM_SETICON / ICON_BIG
                [void][Shell32Ex]::SendMessageW($form.Handle, 0x0080, [IntPtr]0, $hIcon)   # WM_SETICON / ICON_SMALL
                Write-AppLog '窗口大/小图标已显式设置'
            }
        } catch { Write-AppLog ('设置窗口图标失败: ' + $_.Exception.Message) 'WARN' }

        $script:Core.SetVirtualHostNameToFolderMapping('perf.local', $script:Root, [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Allow)
        $script:Core.Navigate('https://perf.local/ui/index.html')

        $script:Core.add_WebMessageReceived({
            param($sender, $e)
            try {
                $msg = $e.WebMessageAsJson | ConvertFrom-Json
            } catch { return }
            Handle-UiMessage $msg
        })
    } catch {
        Write-AppLog ('WebView2 初始化失败: ' + $_.Exception.Message) 'ERROR'
        try {
            [System.Windows.Forms.MessageBox]::Show(
                ($_.Exception.Message + "`n`n详细日志: " + $script:LogFile),
                'PerfCapture', 'OK', 'Error') | Out-Null
        } catch { }
    }
})
