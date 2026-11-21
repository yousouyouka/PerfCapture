# B121 扩展状态机探针：在隔离作用域里 dot-source 真实的 80-Extensions.ps1，
# 用 stub 掉宿主依赖（写日志 / 保存配置 / 回推 UI），驱动状态机全链路与「关闭是真开关」。
# 所有断言都是非空断言；不启动真实进程（payload 指向不存在的测试文件，install 会被如实拒绝）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-extensions-state.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host "== B121 扩展状态机探针 ==" -ForegroundColor Cyan

# ---- stub 宿主依赖 ----
$script:Root = $root
$script:DataDir = Join-Path $env:TEMP 'PerfCapture-B121'
if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
$script:LogLines = New-Object System.Collections.ArrayList
$script:UiMessages = New-Object System.Collections.ArrayList
$script:SavedCount = 0
function Write-AppLog([string]$text, [string]$lvl = 'INFO') { [void]$script:LogLines.Add($text) }
function Send-ToUi([hashtable]$payload) { [void]$script:UiMessages.Add($payload) }
function Save-Config { $script:SavedCount++ }   # 不写盘：持久化语义用 SavedCount + 内存状态验证
$script:Cfg = @{ extensions = @{} }

# ---- 加载真实模块 ----
. (Join-Path $root 'src\app\80-Extensions.ps1')

# ---- 1. 注册表加载与「已发布/规划中」分层 ----
$reg = @(Get-ExtensionRegistry)
Assert ($reg.Count -ge 5) "注册表加载 $($reg.Count) 项" "注册表条目过少：$($reg.Count)"
$rtss = $reg | Where-Object { $_.id -eq 'rtss-shm' }
Assert ($rtss.available) 'RTSS 已发布 available=true（批次 D 首个真实扩展）' 'RTSS 未标记已发布'
Assert (@($reg | Where-Object { -not $_.available }).Count -ge 4) '其余扩展仍规划中（如实未发布）' '规划中扩展少于 4 项'
Assert ($rtss.mode -eq 'external-shm' -and $rtss.shmName -eq 'RTSSSharedMemoryV2') 'RTSS 为外部共享内存模式' 'RTSS 模式/共享内存名错误'
Assert ($null -ne $rtss.package -and $rtss.package.kind -eq 'nsis-zip') 'RTSS 为托管型：package 配置来自注册表（不探测本机预装实例）' 'RTSS 缺 package 配置'

# init JSON 契约：extensions 必须是对象数组，不能是 [[{...}]]。
# 曾因 Get-ExtensionStates 的 return ,$array + 调用方 @() 二次包装，前端拿到 1 个数组元素而渲染空白。
$initJson = @{ type = 'init'; extensions = @(Get-ExtensionStates); fpsSource = $script:ActiveFpsSource } |
    ConvertTo-Json -Depth 6 -Compress
Assert ($initJson -match '"extensions":\[\{') 'init JSON 的 extensions 是对象数组' 'init JSON 的 extensions 不是对象数组'
Assert ($initJson -notmatch '"extensions":\[\[') 'init JSON 的 extensions 未被二次包装成嵌套数组' 'init JSON 出现嵌套数组 [[...]]，前端会渲染空白'

# ---- 2. 托管型 RTSS：状态=notInstalled，安装交给供应层；本探针未加载供应层时如实拒绝 ----
$st0 = Get-ExtensionStateFor $rtss
Assert ($st0 -eq 'notInstalled') '已发布但未安装时状态为 notInstalled' "状态错误：$st0"
$before = @($script:UiMessages).Count
$r = Install-ExtensionCore 'rtss-shm'
$msgs = @($script:UiMessages)[$before..(@($script:UiMessages).Count - 1)]
$err = @($msgs | Where-Object { $_.type -eq 'extensionError' })
Assert (-not $r) '供应层缺席时安装被拒绝（不假成功）' '无供应层竟安装成功'
Assert ($err.Count -eq 1 -and $err[0].reason -eq 'provisionUnavailable') '拒绝原因如实为供应层不可用' "未回推供应层不可用：$(@($err|ForEach-Object{$_.reason}) -join ',')"
Assert ($script:Cfg.extensions.Count -eq 0) '被拒后持久化状态未污染' '被拒后状态被写入'

# ---- 2b. 规划中扩展仍被拒 notAvailable（保留该铁律断言）----
$planned = @($reg | Where-Object { -not $_.available })[0]
$before = @($script:UiMessages).Count
$rp = Install-ExtensionCore $planned.id
$errp = @(@($script:UiMessages)[$before..(@($script:UiMessages).Count - 1)] | Where-Object { $_.reason -eq 'notAvailable' })
Assert (-not $rp -and $errp.Count -eq 1) '规划中扩展安装拒绝且原因 notAvailable' '规划中扩展拒绝原因错误'

# ---- 3. 注入一个「payload 型已发布」测试扩展，驱动完整状态机 ----
# 用克隆条目（外部共享内存型的安装不满足 payloadMissing 语义，故用 payload 型验证该分支）。
$test = $reg[3].PSObject.Copy()   # frameview：非 external-shm
$test.id = 'b121-test'
$test.available = $true
$test.mode = 'payload'
$test.detectProcess = @()
$test.payload = 'tests\__b121_nonexistent_payload.ps1'   # 不存在：install 会走 payloadMissing，验证细分失败
$script:ExtRegistry = @($reg) + @($test)

# 3a. notInstalled
$s1 = Get-ExtensionStateFor $test
Assert ($s1 -eq 'notInstalled') '新发布扩展初始状态 notInstalled' "初始状态错误：$s1"

# 3b. install → payloadMissing（如实细分，不做假安装）
$before = @($script:UiMessages).Count
$r2 = Install-ExtensionCore $test.id
$err2 = @($script:UiMessages)[$before..(@($script:UiMessages).Count - 1)] | Where-Object { $_.reason -eq 'payloadMissing' }
Assert (-not $r2 -and @($err2).Count -eq 1) 'payload 缺失时如实报 payloadMissing' 'payload 缺失未如实报错'

# 3c. 手动置为 installed（模拟一个真实可安装的扩展安装成功），验证 enable/disable/uninstall 状态流转
Set-ExtensionPersistState $test.id 'installed'
Assert ((Get-ExtensionStateFor $test) -eq 'installed') 'installed 状态正确' 'installed 状态错误'
$installedAt = $script:Cfg.extensions[$test.id].installedAt
Assert (-not [string]::IsNullOrEmpty($installedAt)) '安装时间已持久化' '安装时间缺失'

# 3d. disable 在 installed 态幂等，且不抛异常
$r3 = Disable-ExtensionCore $test.id
Assert ($r3 -and (Get-ExtensionStateFor $test) -eq 'installed') '已安装未启用时关闭幂等（仍 installed）' '关闭后状态异常'

# 3e. uninstall → 状态清空
$r4 = Uninstall-ExtensionCore $test.id
Assert ($r4 -and -not $script:Cfg.extensions.ContainsKey($test.id)) '卸载后状态被清除' '卸载后仍有残留状态'

# ---- 4. 「关闭是真开关」四步断言（源码级，防假开关） ----
$src = Get-Content (Join-Path $root 'src\app\80-Extensions.ps1') -Raw -Encoding UTF8
$dis = [regex]::Match($src, 'function Disable-ExtensionCore[\s\S]*?\r?\n}').Value
Assert ($dis -match 'ExtIpc.Remove') '关闭：断开 IPC' '关闭未断 IPC'
Assert ($dis -match 'Stop-ExtensionProcess') '关闭：终止扩展进程' '关闭未终止进程'
Assert ($dis -match "Set-FpsSource 'presentmon'") '关闭：数据源回退零注入基线' '关闭未回退数据源'
Assert ($dis -match 'Set-ExtensionPersistState') '关闭：状态持久化' '关闭未持久化'
Assert ($dis -match 'Send-ExtensionState') '关闭：回推 UI 状态' '关闭未回推状态'

# ---- 5. 数据源仲裁：非法源被拒，presentmon 恒可用 ----
Assert ((Set-FpsSource 'presentmon') -eq $true) 'presentmon 基线数据源恒可用' 'presentmon 被误拒'
$before = @($script:UiMessages).Count
$bad = Set-FpsSource 'rtss-shm'   # 该测试扩展非 enabled，应被拒
Assert (-not $bad) '非启用扩展不能当数据源（互斥仲裁）' '非法数据源被接受'

# ---- 6. 退出清理 ----
Assert ($src -match 'function Stop-AllExtensionProcesses') '存在退出时清理孤儿进程的钩子' '缺退出清理钩子'

Write-Host ""
if ($fail -eq 0) { Write-Host "== B121 通过 ==" -ForegroundColor Green }
else { Write-Host "== B121 失败 $fail 项 ==" -ForegroundColor Red }
exit $fail
