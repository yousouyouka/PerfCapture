# B128 E1 止血探针（2.1.2）：空参数防御 / 配置自检 / 阶段化原因 / 缓存复用。
# 不联网、不装真 RTSS：本地假安装包 + 合成共享内存，直接驱动 runspace worker 取结构化结果。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b128-e1.ps1

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host "== B128 E1 止血探针 ==" -ForegroundColor Cyan

# ---------- stub 宿主依赖 ----------
$script:Root = $root
$script:DataDir = Join-Path $env:TEMP ('PerfCapture-B128-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
$script:UiMessages = New-Object System.Collections.ArrayList
function Write-AppLog([string]$text, [string]$lvl = 'INFO') { }
function Send-ToUi([hashtable]$payload) { [void]$script:UiMessages.Add($payload) }
function Save-Config { }
$script:Cfg = @{ extensions = @{} }

. (Join-Path $root 'src\app\rtss-shm.ps1')
. (Join-Path $root 'src\app\80-Extensions.ps1')
. (Join-Path $root 'src\app\85-ExtensionProvision.ps1')

function Invoke-Worker([hashtable]$S) {
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:ExtensionProvisionWorker).AddArgument($S).AddArgument($script:ExtProvQueue)
    $r = @($ps.Invoke())[0]
    $ps.Dispose()
    Drain-ExtProvQueue
    return $r
}
function Get-Sha([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '').ToUpperInvariant() }
        finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}

# ---------- 1. 配置静态自检 ----------
$rtss = Get-ExtensionEntry 'rtss-shm'
$originalArgs = [string]$rtss.package.processArgs
$originalSha = [string]$rtss.package.sha256
$originalVerify = $rtss.package.verifyTimeoutMs

$rtss.package.processArgs = ''      # 真机故障配置：空串合法，不许在自检里报错
$okEmpty = $true
try { $null = New-ExtensionProvisionSpec $rtss 'oneclick' } catch { $okEmpty = $false }
Assert $okEmpty 'processArgs 留空是合法配置（不逼用户填假参数）' '空 processArgs 被自检误拒'

$rtss.package.sha256 = ''
$rejected = $false
try { $null = New-ExtensionProvisionSpec $rtss 'oneclick' } catch { $rejected = ($_.Exception.Message -like 'packageInvalid:*') }
Assert $rejected '必填字段为空时在发命令前被拒（packageInvalid）' '空必填字段未被自检拦截'

$rtss.package.sha256 = 'NOTHEX'
$badHex = $false
try { $null = New-ExtensionProvisionSpec $rtss 'oneclick' } catch { $badHex = ($_.Exception.Message -like 'packageInvalid:sha256Format*') }
Assert $badHex '哈希格式非法被自检拦截' '非法哈希未被自检拦截'
$rtss.package.sha256 = $originalSha
$rtss.package.verifyTimeoutMs = 1
$badRange = $false
try { $null = New-ExtensionProvisionSpec $rtss 'oneclick' } catch { $badRange = ($_.Exception.Message -like 'packageInvalid:verifyTimeoutMs*') }
Assert $badRange '数值范围越界被自检拦截' '越界数值未被自检拦截'
$rtss.package.verifyTimeoutMs = $originalVerify

# ---------- 2. 源码契约：空参数不进 Start-Process ----------
$provSource = Get-Content (Join-Path $root 'src\app\85-ExtensionProvision.ps1') -Raw -Encoding UTF8
foreach ($need in 'Start-ProvisionProcess', 'Fail-Stage', 'uacCancelled', 'cacheHit', 'installSuccessCodes') {
    Assert ($provSource -match [regex]::Escape($need)) "E1 实现存在：$need" "供应层缺 $need"
}
Assert ($provSource -notmatch 'Start-Process -FilePath \$cmd -ArgumentList \$pargs') '已移除裸传空参数的 Start-Process 调用' '仍存在裸传 $pargs 的调用'
Assert ($provSource -notmatch 'Start-Process -FilePath \$installer -ArgumentList \$startArgs') '安装器调用也走统一启动器' '安装器仍用旧的空数组参数'

# ---------- 3. 构造本地假包与共享内存 ----------
$work = Join-Path $script:DataDir 'fixture'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$installer = Join-Path $work 'install.ps1'
Set-Content -LiteralPath $installer -Value @'
param([string]$Target)
New-Item -ItemType Directory -Path $Target -Force | Out-Null
'@ -Encoding UTF8
$zip = Join-Path $script:DataDir 'fake.zip'   # 不放在 work 内，避免把归档自身打进包
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path $zip) { Remove-Item $zip -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($work, $zip)

$shmName = 'B128_SHM_' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$SIG = [int]0x52545353; $VER = [int]0x0002000D; $ENTRY = 6000; $ARROFF = 64; $ARRSZ = 2
$shm = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($shmName, [int64]($ARROFF + $ARRSZ * $ENTRY))
$va = $shm.CreateViewAccessor()
$va.Write([int64]0x00, [int]$SIG)
$va.Write([int64]0x04, [int]$VER)
$va.Write([int64]0x08, [int]$ENTRY)
$va.Write([int64]0x0C, [int]$ARROFF)
$va.Write([int64]0x10, [int]$ARRSZ)

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
$rtss.package.processArgs = ''                      # 关键：这次故障的确切配置
$rtss.package.processCommand = (Join-Path $env:WINDIR 'System32\where.exe')  # 无参即退出，不挂起
$rtss.package.verifyTimeoutMs = 3000
$rtss.shmName = $shmName

# ---------- 4. 空参数真实执行：不再抛 provisionException ----------
$cache1 = Join-Path $script:DataDir 'cache1'
$dir1 = Join-Path $script:DataDir 'target1'
$spec1 = New-ExtensionProvisionSpec $rtss 'oneclick'
$spec1.cacheDir = $cache1; $spec1.targetDir = $dir1
$r1 = Invoke-Worker $spec1
Assert ($r1.ok -eq $true) "空 processArgs 下供应成功（实际 reason=$($r1.reason) detail=$($r1.detail)）" '空参数仍导致供应失败'
Assert (Test-Path (Join-Path $cache1 'fake.zip')) '哈希通过的归档保留为缓存' '已验证缓存被回滚删除'

# ---------- 5. 缓存复用：源改坏仍能靠缓存完成 ----------
$dir2 = Join-Path $script:DataDir 'target2'
$spec2 = New-ExtensionProvisionSpec $rtss 'oneclick'
$spec2.cacheDir = $cache1; $spec2.targetDir = $dir2
$spec2.url = Join-Path $script:DataDir 'no-such-source.zip'
$before = @($script:UiMessages).Count
$r2 = Invoke-Worker $spec2
$cacheMsgs = @($script:UiMessages)[$before..(@($script:UiMessages).Count - 1)] | Where-Object { $_.type -eq 'extensionProgress' -and $_.detail -eq 'cacheHit' }
Assert ($r2.ok -eq $true) "源不可达时命中缓存仍成功（reason=$($r2.reason)）" '缓存未生效，重复下载导致失败'
Assert ($cacheMsgs.Count -ge 1) '缓存命中经进度消息如实回推' '缓存命中没有任何提示'

# ---------- 6. 阶段化原因：启动失败不再降级成 provisionException ----------
$cache3 = Join-Path $script:DataDir 'cache3'
$dir3 = Join-Path $script:DataDir 'target3'
$spec3 = New-ExtensionProvisionSpec $rtss 'oneclick'
$spec3.cacheDir = $cache3; $spec3.targetDir = $dir3
$spec3.processCommand = Join-Path $script:DataDir 'no-such-exe.exe'
$r3 = Invoke-Worker $spec3
Assert ($r3.reason -eq 'startFailed') "启动阶段异常如实报 startFailed（实际 $($r3.reason)）" '阶段失败仍是笼统 provisionException'
Assert ($r3.detail -match 'start 阶段') 'detail 含阶段名，可直接上屏' "detail 缺阶段名：$($r3.detail)"
Assert ($r3.rolledBack -eq $true -and -not (Test-Path $dir3)) '阶段失败后完整回滚目标目录' '阶段失败后目标目录残留'
Assert (Test-Path (Join-Path $cache3 'fake.zip')) '阶段失败后已验证缓存仍保留' '失败误删可信缓存'

# ---------- 7. 错误上屏链路：detail 随 extensionError 下发 ----------
$extHost = Get-Content (Join-Path $root 'src\app\80-Extensions.ps1') -Raw -Encoding UTF8
Assert ($extHost -match 'detail = \$Detail') '宿主把 detail 一并推给前端' 'extensionError 仍丢掉 detail'
$uiJs = Get-Content (Join-Path $root 'ui\js\extensions.js') -Raw -Encoding UTF8
Assert ($uiJs -match 'toast = \{ text:.*detail: msg\.detail') '前端 toast 保存并展示 detail' '前端没有渲染失败详情'

$va.Dispose(); $shm.Dispose()
Write-Host "== B128 通过 ==" -ForegroundColor Cyan
if ($fail -gt 0) { exit 1 }
exit 0
