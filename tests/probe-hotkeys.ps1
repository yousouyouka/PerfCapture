# 全局热键探针（2.1.16 / F3-1）
#
# 只验证纯换算部分：键名 → 虚拟键码、修饰键 → MOD 位、显示文案。
# 不真正注册热键（那会占用系统组合键、且依赖窗口句柄），注册路径由真机走查。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-hotkeys.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$mod = Join-Path $root 'src\app\52-Hotkeys.ps1'

$script:fail = 0
$script:pass = 0
function Assert($cond, $name, $detail) {
    if ($cond) { $script:pass++; Write-Host ('  OK   ' + $name) -ForegroundColor DarkGray }
    else { $script:fail++; Write-Host ('  FAIL ' + $name + '  ' + $detail) -ForegroundColor Red }
}

if (-not (Test-Path -LiteralPath $mod)) { Write-Host '缺少 52-Hotkeys.ps1' -ForegroundColor Red; exit 1 }
# 模块只在函数内部访问 $form / $script:Cfg，点源本身无副作用
. $mod

Write-Host '== 1. 键名 → 虚拟键码 ==' -ForegroundColor Cyan
$expect = @{ F1 = 0x70; F2 = 0x71; F3 = 0x72; F4 = 0x73; F5 = 0x74; F6 = 0x75; F7 = 0x76; F8 = 0x77; F9 = 0x78; F10 = 0x79; F11 = 0x7A; F12 = 0x7B }
$badKey = @()
foreach ($k in $expect.Keys) {
    $vk = [int](Get-HotkeyVk $k)
    if ($vk -ne $expect[$k]) { $badKey += ($k + '=' + $vk) }
}
Assert ($badKey.Count -eq 0) 'F1–F12 全部映射正确' ($badKey -join ',')
Assert ([int](Get-HotkeyVk 'f9') -eq 0x78) '小写键名也认（f9）' ('实际 ' + (Get-HotkeyVk 'f9'))
Assert ([int](Get-HotkeyVk 'A') -eq 0) '非功能键返回 0（不静默注册错键）' ('实际 ' + (Get-HotkeyVk 'A'))
Assert ([int](Get-HotkeyVk '') -eq 0) '空键名返回 0' ('实际 ' + (Get-HotkeyVk ''))

Write-Host '== 2. 修饰键 → MOD 位（含 MOD_NOREPEAT）==' -ForegroundColor Cyan
$m1 = [int](Get-HotkeyModifiers ([pscustomobject]@{ ctrl = $true; alt = $false; shift = $false }))
$m2 = [int](Get-HotkeyModifiers ([pscustomobject]@{ ctrl = $true; alt = $true; shift = $false }))
$m3 = [int](Get-HotkeyModifiers ([pscustomobject]@{ ctrl = $false; alt = $false; shift = $false }))
Assert (($m1 -band 0x0002) -ne 0) 'Ctrl 位已置' ('0x' + $m1.ToString('X4'))
Assert (($m1 -band 0x0001) -eq 0) '未选 Alt 时 Alt 位为 0' ('0x' + $m1.ToString('X4'))
Assert (($m2 -band 0x0001) -ne 0 -and ($m2 -band 0x0002) -ne 0) 'Ctrl+Alt 两位都置' ('0x' + $m2.ToString('X4'))
Assert (($m1 -band 0x4000) -ne 0) '始终带 MOD_NOREPEAT（防长按连发）' ('0x' + $m1.ToString('X4'))
Assert ($m3 -eq 0x4000) '无修饰键时只有 NOREPEAT' ('0x' + $m3.ToString('X4'))

Write-Host '== 3. 显示文案 ==' -ForegroundColor Cyan
$l1 = Get-HotkeyLabel ([pscustomobject]@{ ctrl = $true; alt = $true; shift = $false; key = 'F9' })
$l2 = Get-HotkeyLabel ([pscustomobject]@{ ctrl = $false; alt = $false; shift = $true; key = 'f12' })
Assert ($l1 -eq 'Ctrl+Alt+F9') 'Ctrl+Alt+F9' ('实际 ' + $l1)
Assert ($l2 -eq 'Shift+F12') '小写键名显示为大写且无多余加号' ('实际 ' + $l2)

Write-Host '== 4. 注册失败必须能说清原因（不静默）==' -ForegroundColor Cyan
$modText = Get-Content -LiteralPath $mod -Raw -Encoding UTF8
Assert ($modText -match '已被其它程序占用') '占用时有明确文案'
Assert ($modText -match "type = 'hotkey'") '命中热键只通知前端，不直接跑采集（避免与界面参数走岔）'
Assert ($modText -match 'UnregisterHotKey') '退出/关闭时会注销'
Assert ($modText -match 'AddMessageFilter') '用消息过滤器接收 WM_HOTKEY（不注入、不挂钩子）'

Write-Host ''
if ($script:fail -gt 0) {
    Write-Host ('== 失败 ' + $script:fail + ' 项 / 通过 ' + $script:pass + ' 项 ==') -ForegroundColor Red
    exit 1
}
Write-Host ('== 通过 ' + $script:pass + ' 项 ==') -ForegroundColor Green
exit 0
