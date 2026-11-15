# 前置：DPI 感知（必须在任何窗口创建前执行）+ 程序集加载

# PerfCapture · 宿主
# 采集引擎: Measure-GamePerf.ps1（PresentMon ETW，零注入）
# 界面: WebView2 渲染 ui/（HTML/CSS/JS），字体、滚动条、动画全部交给浏览器合成

$ErrorActionPreference = 'Stop'

# ---------- DPI 感知（必须在创建任何窗口之前） ----------
# PowerShell 5.1 宿主默认「不感知 DPI」：在 150% 缩放下 Windows 会把整个窗口位图拉伸 1.5 倍，
# WebView2 里再清晰的字体也会被拉糊。这里在创建窗口前声明 Per-Monitor Aware V2。
$dpiCode = @'
using System;
using System.Runtime.InteropServices;
public class PerfDpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("shcore.dll")]  public static extern int  SetProcessDpiAwareness(int v);
    [DllImport("user32.dll")]  public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]  public static extern uint GetDpiForSystem();
    [DllImport("user32.dll")]  public static extern uint GetDpiForWindow(IntPtr h);
}
'@
try { if (-not ('PerfDpi' -as [type])) { Add-Type -TypeDefinition $dpiCode } } catch { }
$script:DpiAware = $false
try { $script:DpiAware = [PerfDpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }   # PER_MONITOR_AWARE_V2
if (-not $script:DpiAware) { try { $script:DpiAware = ([PerfDpi]::SetProcessDpiAwareness(2) -eq 0) } catch { } }
if (-not $script:DpiAware) { try { [void][PerfDpi]::SetProcessDPIAware() } catch { } }
$script:DpiScale = 1.0
try { $script:DpiScale = [PerfDpi]::GetDpiForSystem() / 96.0 } catch { }
if ($script:DpiScale -le 0) { $script:DpiScale = 1.0 }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Web.Extensions
