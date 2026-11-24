# 托盘 / 开机自启配置探针（2.2.2）
#
# 只验证纯配置行为与源码守卫，不写真实注册表、不建窗口：
#   - closeToTray / autoStart 默认关闭，且只接受布尔值
#   - 开启 autoStart 时必须调用 Set-PerfAutoStart（桩函数记录调用）
#   - 20-Settings.ps1 的自启实现用计划任务（RunLevel Highest + AtLogOn），并保留 HKCU Run 兜底
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-tray-autostart.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$script:fail = 0
$script:pass = 0
function Assert($cond, $name, $detail) {
    if ($cond) { $script:pass++; Write-Host ('  OK   ' + $name) -ForegroundColor DarkGray }
    else { $script:fail++; Write-Host ('  FAIL ' + $name + '  ' + $detail) -ForegroundColor Red }
}

# 配置路径指向不存在的临时文件：dot-source 时只建默认值，不读盘、不触发自启写注册表
$script:CfgPath = Join-Path $env:TEMP ('perftray-cfg-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
$script:AutoCalls = @()
function Write-AppLog([string]$m, [string]$lvl = 'INFO') { }
function Register-PerfHotkeys { return $true }
. (Join-Path $root 'src\app\20-Settings.ps1')

# dot-source 后用桩覆盖真实实现：探针绝不碰注册表
function Set-PerfAutoStart {
    param([bool]$Enabled)
    $script:AutoCalls += $Enabled
}

Write-Host '== 1. 默认值 ==' -ForegroundColor Cyan
$cfgDef = New-DefaultConfig
Assert ($cfgDef.closeToTray -eq $false) '关闭到托盘默认关闭' ('实际 ' + $cfgDef.closeToTray)
Assert ($cfgDef.autoStart -eq $false) '开机自启默认关闭' ('实际 ' + $cfgDef.autoStart)

Write-Host '== 2. 布尔校验 ==' -ForegroundColor Cyan
Set-ConfigValue 'closeToTray' $true
Assert ($script:Cfg.closeToTray -eq $true) 'closeToTray 接受 true'
Set-ConfigValue 'closeToTray' 'true'
Assert ($script:Cfg.closeToTray -eq $true) 'closeToTray 不接受字符串（保持原值）' ('实际 ' + $script:Cfg.closeToTray)
Set-ConfigValue 'closeToTray' $false
Assert ($script:Cfg.closeToTray -eq $false) 'closeToTray 可以关回去'

$script:AutoCalls = @()
Set-ConfigValue 'autoStart' $true
Assert ($script:Cfg.autoStart -eq $true) 'autoStart 接受 true'
Assert (@($script:AutoCalls).Count -eq 1 -and $script:AutoCalls[0] -eq $true) '开启 autoStart 立即调用 Set-PerfAutoStart' ('调用次数 ' + @($script:AutoCalls).Count)
Set-ConfigValue 'autoStart' 'yes'
Assert ($script:Cfg.autoStart -eq $true -and @($script:AutoCalls).Count -eq 1) 'autoStart 不接受字符串（不重复写注册表）' ('调用次数 ' + @($script:AutoCalls).Count)

Write-Host '== 3. 自启实现守卫 ==' -ForegroundColor Cyan
$src = Get-Content (Join-Path $root 'src\app\20-Settings.ps1') -Raw -Encoding UTF8
Assert ($src -match 'Register-ScheduledTask') '自启使用计划任务（可最高权限启动，不弹 UAC）'
Assert ($src -match 'RunLevel Highest') '计划任务运行级别为最高权限'
Assert ($src -match 'AtLogOn') '计划任务在登录时触发'
Assert ($src -match 'PerfCapture-Autostart') '任务名固定为 PerfCapture-Autostart'
Assert ($src -match "'PerfCapture'") '兜底登录项值名为 PerfCapture'
Assert ($src -match '--autostart') '启动参数带 --autostart'
Assert ($src -match 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run') '保留 HKCU Run 作为兜底路径'
Assert ($src -notmatch 'HKLM:|New-Service') '不使用 HKLM / 服务'
Assert ($src -match 'function Sync-PerfAutoStart') '存在 Sync-PerfAutoStart（启动时按配置校正）'

Write-Host ''
if ($script:fail -gt 0) {
    Write-Host ('== 失败 ' + $script:fail + ' 项 / 通过 ' + $script:pass + ' 项 ==') -ForegroundColor Red
    exit 1
}
Write-Host ('== 通过 ' + $script:pass + ' 项 ==') -ForegroundColor Green
exit 0
