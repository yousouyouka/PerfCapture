# B141 扩展运行期看护探针：验证意外退出的指数退避重启（最多 2 次）、
# 用户主动关闭不重启、重启均失败后转 failed 并回退零注入基线。
# 用可控的 stub 驱动 Invoke-ExtensionWatchdogTick，不依赖真实 RTSS 进程。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b141-watchdog.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host '== B141 扩展运行期看护探针 ==' -ForegroundColor Cyan

# ---- 加载真实源文件（stub 宿主依赖后 dot-source）----
$script:Root = $root
$script:DataDir = Join-Path $env:TEMP 'B141-watchdog-data'
$script:Cfg = @{ extensions = @{} }
$script:ActiveFpsSource = 'presentmon'
$script:Logs = New-Object System.Collections.ArrayList
function Write-AppLog([string]$m, [string]$lv = 'INFO') { [void]$script:Logs.Add($lv + ':' + $m) }
function Save-Config { $script:ConfigSaves = 1 + [int]$script:ConfigSaves }
function Send-ToUi($o) { [void]$script:Ui.Add($o) }
function Get-RtssFrameSnapshot { param([string]$ShmName) return @{ ok = $false; reason = 'shmNotFound' } }
$script:Ui = New-Object System.Collections.ArrayList

. (Join-Path $root 'src\app\80-Extensions.ps1')

foreach ($fn in 'Invoke-ExtensionWatchdogTick', 'Set-ExtensionWatchSuppressed', 'Set-ExtensionWatchFailed', 'Test-ExtensionWatchAlive') {
    Assert ((Get-Command $fn -ErrorAction SilentlyContinue) -ne $null) "已加载 $fn" "$fn 未定义"
}

# ---- 可控场景：一个已启用的托管扩展，进程始终不在 ----
$entry = [pscustomobject]@{
    id = 'rtss-shm'; name = 'RTSS'; available = $true; mode = 'external-shm'
    package = [pscustomobject]@{ kind = 'nsis-zip' }; shmName = 'RTSSSharedMemoryV2'
    lifecycle = [pscustomobject]@{ managed = $true; autoStart = $true }
}
$script:FakeEntry = $entry
$script:CopyResults = @('unavailable', 'unavailable', 'started')
$script:CopyCalls = 0
$script:Now = Get-Date '2026-11-22 12:00:00'

function Get-ExtensionRegistry { return @($script:FakeEntry) }
function Get-ExtensionEntry([string]$Id) { return $script:FakeEntry }
$script:FakeAlive = $false
function Get-Process { param($Id, $Name) if ($script:FakeAlive) { return [pscustomobject]@{ Id = $Id; Path = (Join-Path (Get-ExtensionInstallRoot 'rtss-shm') 'RTSS.exe') } }; return $null }
$script:WatchRoot = [IO.Path]::GetFullPath((Join-Path $env:TEMP 'B141-watchdog-data\extensions\rtss-shm'))
$script:WatchRoot = (Get-Item -LiteralPath $script:DataDir -ErrorAction SilentlyContinue).FullName
if (-not $script:WatchRoot) { $script:WatchRoot = [IO.Path]::GetFullPath((Join-Path $env:TEMP 'B141-watchdog-data')) }
$script:WatchRoot = Join-Path $script:WatchRoot 'extensions\rtss-shm'
function Get-ExtensionInstallRoot([string]$Id) { return (Resolve-ExtensionFsPath $script:WatchRoot) }
function Get-Date { if ($script:Now) { return $script:Now }; return [DateTime]::Now }
function Start-ExtensionCopy($Entry, [int]$ReadyWaitMs = 4000) {
    $script:CopyCalls++
    $i = [Math]::Min($script:CopyCalls - 1, $script:CopyResults.Count - 1)
    return $script:CopyResults[$i]
}
function Set-FpsSource([string]$Source) { $script:ActiveFpsSource = $Source; return $true }
function Send-ExtensionState([string]$Id) { [void]$script:Ui.Add(@{ type = 'extensionState'; id = $Id }) }

# 置初始持久化状态：已启用 + 本软件拉起 + 自启
Set-ExtensionPersistState 'rtss-shm' 'enabled' '' @{
    installedPath = (Join-Path $script:DataDir 'extensions\rtss-shm')
    installPid = 424242
    startedByUs = $true
    autoStart = $true
    installedVersion = '7.3.7'
}
Assert ((Test-ExtensionWatchAlive $entry) -eq $false) '假进程不存在时判为不存活' '存活判定错误（应为 false）'

# ---- 场景 1：用户主动关闭 → 抑制窗内绝不重启 ----
Set-ExtensionWatchSuppressed 'rtss-shm' 6
$script:CopyCalls = 0
Invoke-ExtensionWatchdogTick
Assert ($script:CopyCalls -eq 0) '用户关闭后抑制窗内不重启' ("抑制失效：重启调用 $($script:CopyCalls) 次")

# 时间前进到抑制窗之后
$script:Now = $script:Now.AddSeconds(7)
$script:CopyResults = @('unavailable', 'unavailable', 'unavailable')
$script:CopyCalls = 0
$script:ActiveFpsSource = 'rtss-shm'

# ---- 场景 2：第一次 tick → 第 1 次重启（失败）----
Invoke-ExtensionWatchdogTick
Assert ($script:CopyCalls -eq 1) '进程意外退出后触发第 1 次重启' "第 1 次重启未触发：calls=$($script:CopyCalls)"
Assert ($script:ExtWatch['rtss-shm'].attempts -eq 1) '退避计数记为 1' "退避计数错误：$($script:ExtWatch['rtss-shm'].attempts)"

# 退避窗内（2 秒）不重复重启
Invoke-ExtensionWatchdogTick
Assert ($script:CopyCalls -eq 1) '退避窗内不重复重启' "退避失效：calls=$($script:CopyCalls)"

# ---- 场景 3：第二次 tick（+3 秒）→ 第 2 次重启（失败）----
$script:Now = $script:Now.AddSeconds(3)
Invoke-ExtensionWatchdogTick
Assert ($script:CopyCalls -eq 2) '退避后触发第 2 次重启' "第 2 次重启未触发：calls=$($script:CopyCalls)"

# ---- 场景 4：第三次 tick（+5 秒）→ 达 2 次上限，转 failed 并回退基线 ----
$script:Now = $script:Now.AddSeconds(5)
Invoke-ExtensionWatchdogTick
Assert ($script:CopyCalls -eq 2) '达到 2 次上限后不再重启' "超限仍重启：calls=$($script:CopyCalls)"
Assert ((Get-ExtensionPersistState 'rtss-shm') -eq 'failed') '重启均失败后状态转 failed' "状态未转 failed：$(Get-ExtensionPersistState 'rtss-shm')"
Assert ($script:ActiveFpsSource -eq 'presentmon') '失败后数据源回退 presentmon' "数据源未回退：$($script:ActiveFpsSource)"
$bag = Get-ExtensionBag
Assert ([bool]$bag['rtss-shm'].startedByUs -eq $false) '失败后清除 startedByUs 标记' '失败后仍自称拥有进程'
Assert ($bag['rtss-shm'].reason -eq 'watchdogRestartFailed') '失败原因细分为 watchdogRestartFailed' "原因错误：$($bag['rtss-shm'].reason)"
Assert (-not $script:ExtWatch.ContainsKey('rtss-shm')) '失败后清除看护记录' '失败后看护记录仍在'

# ---- 场景 5：重启成功 → 计数清零、失败态不误判 ----
Set-ExtensionPersistState 'rtss-shm' 'enabled' '' @{
    installedPath = (Join-Path $script:DataDir 'extensions\rtss-shm')
    installPid = 424242; startedByUs = $true; autoStart = $true
}
$script:CopyResults = @('started')
$script:CopyCalls = 0
$script:Now = $script:Now.AddSeconds(1)
Invoke-ExtensionWatchdogTick
Assert ($script:CopyCalls -eq 1) 'enabled 状态会尝试重启' 'enabled 状态未触发重启'
# 模拟重启后进程重新存活
$script:FakeAlive = $true
$script:Now = $script:Now.AddSeconds(5)
Invoke-ExtensionWatchdogTick
Assert ($script:ExtWatch['rtss-shm'].attempts -eq 0) '进程恢复后退避计数清零' "计数未清零：$($script:ExtWatch['rtss-shm'].attempts)"

# ---- 场景 6：autoStart=false 的扩展不被看护 ----
Set-ExtensionPersistState 'rtss-shm' 'enabled' '' @{
    installedPath = (Join-Path $script:DataDir 'extensions\rtss-shm')
    installPid = 424242; startedByUs = $true; autoStart = $false
}
$script:FakeAlive = $false
$script:CopyCalls = 0
Invoke-ExtensionWatchdogTick
Assert ($script:CopyCalls -eq 0) 'autoStart=false 的扩展不被看护重启' "误重启了 autoStart=false：calls=$($script:CopyCalls)"

Write-Host '== B141 通过 ==' -ForegroundColor Cyan
if ($fail -gt 0) { Write-Host ("失败断言 $fail 项") -ForegroundColor Red; exit 1 }
exit 0
