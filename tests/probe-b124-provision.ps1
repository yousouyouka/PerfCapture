# B124–B127 扩展供应探针：一键安装 / 随软件自启 / 关闭与卸载 / 失败回滚。
# 不联网、不装真 RTSS：用注册表里显式开启的本地假安装包走完整供应链，
# 共享内存用真实 MemoryMappedFile 占位，进程用安装目录内的 PowerShell 副本模拟。
# 所有断言非空；任何一步失败都必须回滚，不留下状态或进程。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b124-provision.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms

$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host "== B124–B127 扩展供应探针 ==" -ForegroundColor Cyan

# ---------- stub 宿主依赖 ----------
$script:Root = $root
$script:DataDir = Join-Path $env:TEMP ('PerfCapture-B124-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
$script:UiMessages = New-Object System.Collections.ArrayList
$script:LogLines = New-Object System.Collections.ArrayList
function Write-AppLog([string]$text, [string]$lvl = 'INFO') { [void]$script:LogLines.Add(($lvl + ' ' + $text)) }
function Send-ToUi([hashtable]$payload) { [void]$script:UiMessages.Add($payload) }
function Save-Config { }
$script:Cfg = @{ extensions = @{} }

. (Join-Path $root 'src\app\rtss-shm.ps1')
. (Join-Path $root 'src\app\80-Extensions.ps1')
. (Join-Path $root 'src\app\85-ExtensionProvision.ps1')

function Wait-Provision {
    $n = 0
    while ($script:ExtProvCtx -and $n -lt 400) {
        Invoke-ExtProvTick
        Start-Sleep -Milliseconds 25
        $n++
    }
    if ($script:ExtProvCtx) { Bad '供应任务未在超时前完成' }
}

function Get-Sha([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '').ToUpperInvariant() }
        finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}

# ---------- 构造本地假安装包 ----------
$work = Join-Path $script:DataDir 'fixture'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$installer = Join-Path $work 'install.ps1'
$installerBody = @'
param([string]$Target)
New-Item -ItemType Directory -Path $Target -Force | Out-Null
$ps = (Get-Command powershell.exe).Source
Copy-Item -LiteralPath $ps -Destination (Join-Path $Target 'powershell.exe') -Force
Set-Content -LiteralPath (Join-Path $Target 'run.ps1') -Value 'Start-Sleep -Seconds 60' -Encoding UTF8
'@
Set-Content -LiteralPath $installer -Value $installerBody -Encoding UTF8
$zip = Join-Path $work 'fake.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -LiteralPath $installer -DestinationPath $zip -Force

$rtss = Get-ExtensionEntry 'rtss-shm'
$shmName = 'B124_SHM_' + [guid]::NewGuid().ToString('N').Substring(0, 12)

# 合成一份真实 RTSSSharedMemoryV2，避免读取器把占位共享内存判成 badSignature。
$SIG = [int]0x52545353; $VER = [int]0x0002000D; $ENTRY = 6000; $ARROFF = 64; $ARRSZ = 2
$shm = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($shmName, [int64]($ARROFF + $ARRSZ * $ENTRY))
$va = $shm.CreateViewAccessor()
$va.Write([int64]0x00, [int]$SIG)
$va.Write([int64]0x04, [int]$VER)
$va.Write([int64]0x08, [int]$ENTRY)
$va.Write([int64]0x0C, [int]$ARROFF)
$va.Write([int64]0x10, [int]$ARRSZ)
$base = [int64]($ARROFF)
$va.Write([int64]($base + 0x000), [int]4242)
$nameBytes = [Text.Encoding]::ASCII.GetBytes('game.exe')
for ($k = 0; $k -lt $nameBytes.Length; $k++) { $va.Write([int64]($base + 0x004 + $k), [byte]$nameBytes[$k]) }
$va.Write([int64]($base + 0x004 + $nameBytes.Length), [byte]0)
$va.Write([int64]($base + 0x110), [int][Environment]::TickCount)
for ($j = 0; $j -lt 100; $j++) { $va.Write([int64]($base + 0x39C + $j * 4), [int]10000) }
function Refresh-ShmTime { $va.Write([int64]($base + 0x110), [int][Environment]::TickCount) }

# 用注册表驱动供应层：路径/版本/参数全部来自 spec，worker 不含硬编码。
$rtss.package.sourceKind = 'file'
$rtss.package.allowLocalSource = $true
$rtss.package.url = $zip
$rtss.package.sha256 = Get-Sha $zip
$rtss.package.archiveName = 'fake.zip'
$rtss.package.installerRelative = 'install.ps1'
$rtss.package.installerKind = 'script'
$rtss.package.installArgs = '-Target "{DIR}"'
$rtss.package.elevateInstall = $false
$rtss.package.requireSignature = $false
$rtss.package.installerSha256 = ''
$rtss.package.processCommand = '{DIR}\powershell.exe'
$rtss.package.processArgs = '-NoProfile -ExecutionPolicy Bypass -File "{DIR}\run.ps1"'
$rtss.package.verifyTimeoutMs = 6000
$rtss.shmName = $shmName

# ---------- B124 一键启用：下载 → 校验 → 安装 → 配置 → 启动 → 验共享内存 ----------
[void](Start-ExtensionProvision 'rtss-shm' 'oneclick')
Wait-Provision
$failLogs = @($script:LogLines | Where-Object { $_ -match '扩展供应失败' })
if ($failLogs.Count) { Write-Host ('  DEBUG ' + ($failLogs[-1])) -ForegroundColor DarkYellow }

$prog = @($script:UiMessages | Where-Object { $_.type -eq 'extensionProgress' } | ForEach-Object { $_.stage })
Assert ($prog -contains 'download' -and $prog -contains 'verify' -and $prog -contains 'install' -and $prog -contains 'configure' -and $prog -contains 'start' -and $prog -contains 'done') '阶段进度逐项回推（下载/校验/安装/配置/启动/完成）' "阶段进度缺失：$(@($prog) -join ',')"

$st = (Get-ExtensionStates | Where-Object { $_.id -eq 'rtss-shm' })
Assert ($st.status -eq 'enabled') "一键启用后状态为 enabled" "一键启用未进入 enabled：status=$($st.status) reason=$($st.reason)"
$bag = Get-ExtensionBag
$own = $bag['rtss-shm']
Assert ($own.installedPath -and (Test-Path $own.installedPath)) '安装目录来自 spec 且真实存在' '安装目录缺失'
Assert ([int]$own.installPid -gt 0 -and [bool]$own.startedByUs -and [bool]$own.autoStart) '自有 PID / startedByUs / autoStart 已持久化' '自有运行态字段缺失'
$cfgPath = Join-Path $own.installedPath 'ProfileTemplates\Config'
Assert ((Test-Path $cfgPath) -and ((Get-Content $cfgPath -Raw) -match 'Silent=1')) '私有配置按 spec 写入（键来自注册表）' '私有配置写入失败'
$dep = Test-ExtensionDependency $rtss
Assert ($dep.ok -and $dep.missing.Count -eq 0) '依赖探测只看自有副本与共享内存（无视本机预装 RTSS）' "自有依赖判定失败：$(@($dep.missing) -join ',')"
$proc = Get-Process -Id ([int]$own.installPid) -ErrorAction SilentlyContinue
Assert ($null -ne $proc) '自有进程确实在运行' '自有进程未启动'

# ---------- B126 关闭：结束自有进程回，退数据源，保留安装目录 ----------
[void](Disable-ExtensionCore 'rtss-shm')
Start-Sleep -Milliseconds 150
$proc2 = Get-Process -Id ([int]$own.installPid) -ErrorAction SilentlyContinue
Assert ($null -eq $proc2) '关闭后自有进程已结束（真开关）' '关闭后自有进程仍存活'
Assert ($script:ActiveFpsSource -eq 'presentmon') '关闭后数据源回退零注入基线' "数据源未回退：$($script:ActiveFpsSource)"
Assert ((Get-ExtensionPersistState 'rtss-shm') -eq 'installed') '关闭后状态为已安装未启用（非卸载）' '关闭后状态错误'
Assert (Test-Path $own.installedPath) '关闭不删除自有安装目录' '关闭误删安装文件'

# ---------- B125 随软件自启：enabled 项在下次启动时恢复 ----------
Set-ExtensionPersistState 'rtss-shm' 'enabled' '' @{ installedPath = $own.installedPath; installedVersion = '7.3.7'; installPid = 999999; startedByUs = $true; autoStart = $true }
Refresh-ShmTime
Start-EnabledExtensions
Wait-Provision
Refresh-ShmTime
$st2 = (Get-ExtensionStates | Where-Object { $_.id -eq 'rtss-shm' })
Assert ($st2.status -eq 'enabled') "自启后状态恢复为 enabled" "自启未恢复 enabled：status=$($st2.status) reason=$($st2.reason)"
$own2 = (Get-ExtensionBag)['rtss-shm']
$proc3 = Get-Process -Id ([int]$own2.installPid) -ErrorAction SilentlyContinue
Assert ($null -ne $proc3) '自启拉起了新的自有进程' '自启未拉起进程'
# 复用已安装副本：进程被杀后重启，只启动、不重装（否则每次开软件都要再等安装、再点 UAC）。
$reuseLogs = @($script:LogLines | Where-Object { $_ -match '复用已安装副本' })
Assert ($reuseLogs.Count -ge 1) '自启复用已安装副本（不重复安装、不再弹 UAC）' '自启又走了一遍安装流程'

# ---------- 卸载：状态清除 + 目录删除 + 进程结束 ----------
[void](Uninstall-ExtensionCore 'rtss-shm')
Start-Sleep -Milliseconds 150
Assert (-not (Get-ExtensionPersistState 'rtss-shm')) '卸载后持久化状态清除' '卸载后状态残留'
Assert (-not (Test-Path $own.installedPath)) '卸载后自有目录清除' '卸载后目录残留'

# ---------- B127 失败回滚：哈希不符不得安装、不得写状态 ----------
$badDir = Join-Path $script:DataDir 'bad-target'
$rtss.package.url = $zip
$rtss.package.sha256 = '0000000000000000000000000000000000000000000000000000000000000000'
$beforeMsg = @($script:UiMessages).Count
$spec = New-ExtensionProvisionSpec $rtss 'oneclick'
$spec.targetDir = $badDir
$spec.cacheDir = Join-Path $script:DataDir 'bad-cache'
# 直接跑 worker 的结果，验证失败路径本身（Start-ExtensionProvision 走同样 spec）。
$ps = [PowerShell]::Create()
[void]$ps.AddScript($script:ExtensionProvisionWorker).AddArgument($spec).AddArgument($script:ExtProvQueue)
$badResult = @($ps.Invoke())[0]
$ps.Dispose()
Assert (-not $badResult.ok -and $badResult.reason -eq 'hashMismatch') "校验失败如实报 hashMismatch（实际 $($badResult.reason)）" '哈希失败未被识别'
Assert ($badResult.rolledBack) '校验失败后执行回滚' '校验失败未回滚'
Assert (-not (Test-Path $badDir)) '回滚后没有残留目标目录' '回滚后目标目录残留'

$va.Dispose(); $shm.Dispose()
Write-Host "== B124–B127 通过 ==" -ForegroundColor Cyan
if ($fail -gt 0) { exit 1 }
exit 0
