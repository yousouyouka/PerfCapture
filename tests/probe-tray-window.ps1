# 托盘隐藏 / 还原探针（2.2.3）
#
# 验证「不改 ShowInTaskbar」的隐藏方案不会重建窗口句柄：
#   1) Hide 后 Handle 与隐藏前完全一致（闪回的根因就是句柄被重建）
#   2) 窗口仍 Visible（ShowDialog 的模态条件依赖可见，Hide() 会让主循环退出）
#   3) 扩展样式正确设置 / 清除 WS_EX_TOOLWINDOW
#   4) Show 回原位置后句柄依旧不变
#
# 直接使用 src\app\90-Main.ps1 里的 $trayWinCs 源码，避免测试与实现漂移。
# 用法：powershell -STA -NoProfile -ExecutionPolicy Bypass -File tests\probe-tray-window.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$script:fail = 0
$script:pass = 0
function Assert($cond, $name, $detail) {
    if ($cond) { $script:pass++; Write-Host ('  OK   ' + $name) -ForegroundColor DarkGray }
    else { $script:fail++; Write-Host ('  FAIL ' + $name + '  ' + $detail) -ForegroundColor Red }
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$src = Get-Content (Join-Path $root 'src\app\90-Main.ps1') -Raw -Encoding UTF8
if ($src -notmatch "(?s)\`$trayWinCs = @'\r?\n(.*?)\r?\n'@") {
    Write-Host '  FAIL 未能从 90-Main.ps1 提取 PcTrayWindow 源码' -ForegroundColor Red
    exit 1
}
Add-Type -TypeDefinition $Matches[1] -Language CSharp

$form = New-Object System.Windows.Forms.Form
$form.Text = 'tray-probe'
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(80, 80)
$form.Size = New-Object System.Drawing.Size(360, 220)
$form.ShowInTaskbar = $true
Write-Host '== 1. 隐藏 ==' -ForegroundColor Cyan
$form.Show()
[System.Windows.Forms.Application]::DoEvents()
$h0 = $form.Handle
Assert ($h0 -ne [IntPtr]::Zero) '窗口句柄已创建'
Assert ($form.Visible) '显示后 Visible = true'

[PcTrayWindow]::Hide($h0, -32000, -32000)
[System.Windows.Forms.Application]::DoEvents()
$h1 = $form.Handle
$exHide = [PcTrayWindow]::GetWindowLong($h1, -20)
Assert ($h1 -eq $h0) '隐藏后句柄不变（不会闪回）' ("h0=$h0 h1=$h1")
Assert ($form.Visible) '隐藏只是移出屏幕，窗口仍 Visible（模态循环不退出）'
Assert (($exHide -band 0x80) -ne 0) '隐藏后带 WS_EX_TOOLWINDOW（任务栏/Alt-Tab 不占位）' ('ex=0x{0:X}' -f $exHide)
Assert (($exHide -band 0x40000) -eq 0) '隐藏后 WS_EX_APPWINDOW 已清除'

Write-Host '== 2. 还原 ==' -ForegroundColor Cyan
[PcTrayWindow]::Show($h1, 80, 80)
[System.Windows.Forms.Application]::DoEvents()
$h2 = $form.Handle
$exShow = [PcTrayWindow]::GetWindowLong($h2, -20)
$loc = $form.Location
Assert ($h2 -eq $h0) '还原后句柄仍不变' ("h0=$h0 h2=$h2")
Assert (($exShow -band 0x80) -eq 0) '还原后 WS_EX_TOOLWINDOW 已清除'
Assert (($exShow -band 0x40000) -ne 0) '还原后带 WS_EX_APPWINDOW（任务栏恢复）'
Assert ($loc.X -eq 80 -and $loc.Y -eq 80) '还原回原位置' ("x=$($loc.X) y=$($loc.Y)")

Write-Host '== 3. 第二轮（复用任务栏 COM 对象） ==' -ForegroundColor Cyan
[PcTrayWindow]::Hide($h2, -32000, -32000)
[System.Windows.Forms.Application]::DoEvents()
$h3 = $form.Handle
Assert ($h3 -eq $h0) '第二次隐藏句柄仍不变'
Assert ($form.Visible) '第二次隐藏仍保持 Visible'
Assert (([PcTrayWindow]::GetWindowLong($h3, -20) -band 0x80) -ne 0) '第二次隐藏仍带 WS_EX_TOOLWINDOW'
[PcTrayWindow]::Show($h3, 80, 80)
[System.Windows.Forms.Application]::DoEvents()
$h4 = $form.Handle
Assert ($h4 -eq $h0) '第二次还原句柄仍不变'
Assert (([PcTrayWindow]::GetWindowLong($h4, -20) -band 0x80) -eq 0) '第二次还原已清除 WS_EX_TOOLWINDOW'

try { $form.Close(); $form.Dispose() } catch { }

Write-Host ''
if ($script:fail -gt 0) {
    Write-Host ('== 失败 ' + $script:fail + ' 项 / 通过 ' + $script:pass + ' 项 ==') -ForegroundColor Red
    exit 1
}
Write-Host ('== 通过 ' + $script:pass + ' 项 ==') -ForegroundColor Green
exit 0
