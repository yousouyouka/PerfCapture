# B123 扩展崩溃隔离探针：扩展进程消失/共享内存失效后，宿主状态机仍正常工作，
# 如实给出 failed + 细分原因，主数据源可回退基线；宿主自身的采集状态不被污染。
# 与 B141（看护重启）互补：本探针只验「隔离与如实上报」，不期望进程被拉起。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b123-ext-isolation.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host '== B123 扩展崩溃隔离探针 ==' -ForegroundColor Cyan

$script:Root = $root
$script:DataDir = Join-Path $env:TEMP ('PerfCapture-B123-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:UiMessages = New-Object System.Collections.ArrayList
function Write-AppLog([string]$text, [string]$lvl = 'INFO') { }
function Send-ToUi($payload) { [void]$script:UiMessages.Add($payload) }
function Save-Config { }
$script:Cfg = @{ extensions = @{} }
. (Join-Path $root 'src\app\rtss-shm.ps1')
. (Join-Path $root 'src\app\80-Extensions.ps1')

# 条目：external-shm、自有副本式（package.kind），进程已不在、共享内存未就绪
$entry = [pscustomobject]@{
    id = 'b123-shm'; name = 'B123'; desc = ''; category = 'datasource'; metrics = @('FPS')
    depends = ''; size = ''; permission = ''; platform = ''; cost = ''; source = ''
    version = '1.0.0'; available = $true; mode = 'external-shm'; shmName = 'B123MissingShm'
    detectProcess = @(); payload = ''; package = [pscustomobject]@{ kind = 'nsis-zip' }
    lifecycle = [pscustomobject]@{ managed = $true }
}
$script:ExtRegistry = @($entry)
$script:ExtLoaded = $true
function Get-Process { param($Id, $Name) return $null }
function Get-RtssFrameSnapshot { param([string]$ShmName) return @{ ok = $false; reason = 'shmNotFound'; fps = $null } }
# 注意：Set-FpsSource 用真实的（在 80-Extensions.ps1 里），它会按状态机拒绝失效的扩展源。

# ---- 1. 扩展「已启用」但运行时全没了 → 状态机如实报 failed，不抛异常 ----
Set-ExtensionPersistState 'b123-shm' 'enabled' '' @{
    installedPath = (Join-Path $script:DataDir 'b123-shm')
    installPid = 999999; startedByUs = $true; autoStart = $true
}
$state = $null
$err = $null
try { $state = Get-ExtensionStateFor $entry } catch { $err = $_ }
Assert ($null -eq $err) '扩展运行时消失时状态计算不抛异常' ("状态计算抛异常: $err")
Assert ($state -eq 'failed') '状态如实转为 failed（不谎报 enabled）' "期望 failed，实际 $state"

$reason = Get-ExtensionStateReason 'b123-shm' $state
Assert ($reason -eq 'shmNotFound' -or $reason -eq 'ownProcessMissing' -or $reason -like 'shm:*') `
    '失败原因细分为共享内存/进程缺失（不是笼统「暂不可用」）' "原因不够细: $reason"

# ---- 2. 数据源读取失败不得伪造 FPS 数值 ----
$snap = Get-ActiveExtensionFps
Assert ($null -eq $snap -or -not $snap.ok) '扩展失效时不返回虚构帧数据' '扩展失效时仍返回 ok 帧数据'

# ---- 3. 下发状态数组结构不崩、字段齐全（宿主后续采集/ui 不因单个扩展坏掉而中断）----
$states = @()
$err2 = $null
try { $states = @(Get-ExtensionStates) } catch { $err2 = $_ }
Assert ($null -eq $err2) 'Get-ExtensionStates 在扩展故障下不抛异常' ("下发状态抛异常: $err2")
Assert ($states.Count -eq 1 -and $states[0].id -eq 'b123-shm') '故障扩展仍出现在状态列表（不消失、不隐藏）' "状态列表异常: count=$($states.Count)"
Assert ($states[0].status -eq 'failed') '下发的 status 如实为 failed' "下发状态: $($states[0].status)"

# ---- 4. 回退基线：Set-FpsSource 拒绝坏源，宿主仍可用 presentmon ----
$script:ActiveFpsSource = 'presentmon'
$accepted = Set-FpsSource 'b123-shm'
Assert ($accepted -eq $false) '数据源仲裁拒绝已失效的扩展源' '坏源被错误接受'
Assert ($script:ActiveFpsSource -eq 'presentmon') '拒绝后仍保持零注入基线' "数据源被污染: $($script:ActiveFpsSource)"

# ---- 5. 未启用扩展的故障不影响已发布项的可用性 ----
$entry2 = [pscustomobject]@{
    id = 'b123-other'; name = 'Other'; available = $true; mode = 'external-shm'; shmName = ''
    detectProcess = @(); payload = ''; package = $null; lifecycle = $null
}
$script:ExtRegistry = @($entry, $entry2)
$both = @(Get-ExtensionStates)
Assert ($both.Count -eq 2) '一个扩展故障不影响其它扩展的状态计算' "状态数异常: $($both.Count)"
Assert ($both[1].status -eq 'notInstalled') '其它未装扩展仍如实为 notInstalled' "其它扩展状态: $($both[1].status)"

Write-Host '== B123 通过 ==' -ForegroundColor Cyan
if ($fail -gt 0) { Write-Host ("失败断言 $fail 项") -ForegroundColor Red; exit 1 }
exit 0
