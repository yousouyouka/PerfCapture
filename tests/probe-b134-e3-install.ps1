# B134 E3 安装确认探针（2.1.7）：安装器类型自适应 / 成功码 / 配置回读 / 共享内存细分 / 诊断包 / 完全回滚。
# 不联网、不装真 RTSS：本地假安装包 + 合成共享内存，直接驱动 runspace worker 取结构化结果。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b134-e3-install.ps1

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host "== B134 E3 安装确认探针 ==" -ForegroundColor Cyan

# ---------- stub 宿主依赖 ----------
$script:Root = $root
$script:DataDir = Join-Path $env:TEMP ('PerfCapture-B134-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
$script:UiMessages = New-Object System.Collections.ArrayList
function Write-AppLog([string]$text, [string]$lvl = 'INFO') { }
function Send-ToUi([hashtable]$payload) { [void]$script:UiMessages.Add($payload) }
function Save-Config { }
$script:Cfg = @{ extensions = @{} }

. (Join-Path $root 'src\app\06-NetProxy.ps1')
. (Join-Path $root 'src\app\rtss-shm.ps1')
. (Join-Path $root 'src\app\80-Extensions.ps1')
. (Join-Path $root 'src\app\85-ExtensionProvision.ps1')

# Get-InstallerPlan 只服务供应流程，定义在 worker 源码里。这里把那段函数源码取出来单独执行：
# 测的是**同一份实现**，不是复制粘贴的假副本（复制一份就失去回归价值）。
$wkSrc = [string]$script:ExtensionProvisionWorker
$iFn = $wkSrc.IndexOf('function Get-InstallerPlan')
$jFn = $wkSrc.IndexOf('function Start-ProvisionProcess')
Assert ($iFn -ge 0 -and $jFn -gt $iFn) '能从 worker 源码定位 Get-InstallerPlan' 'worker 里找不到 Get-InstallerPlan（探针需同步更新）'
if ($iFn -ge 0 -and $jFn -gt $iFn) {
    . ([scriptblock]::Create($wkSrc.Substring($iFn, $jFn - $iFn)))
}

function Get-Sha([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '').ToUpperInvariant() }
        finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}
function Invoke-Worker([hashtable]$S) {
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:ExtensionProvisionWorker).AddArgument($S).AddArgument($script:ExtProvQueue).AddArgument('').AddArgument([string]$script:NetProxyHelper)
    $r = @($ps.Invoke())[0]
    $ps.Dispose()
    Drain-ExtProvQueue
    return $r
}

# ---------- 1. 安装器类型自适应：一张表决定怎么启动，不在下游写扩展专属分支 ----------
$planMsi = Get-InstallerPlan 'msi' 'C:\Program Files\a b\setup.msi' '/qn'
Assert ($planMsi.file -eq 'msiexec.exe') 'msi 交给 msiexec' "msi 启动文件不对：$($planMsi.file)"
Assert ($planMsi.args -match '^/i "C:\\Program Files\\a b\\setup\.msi" /qn$') "msi 参数含引号包裹的安装包路径（$($planMsi.args)）" "msi 参数不对：$($planMsi.args)"
Assert ($planMsi.elevate -eq $true) 'msi 默认需要提权' 'msi 默认不提权'

$planScript = Get-InstallerPlan 'script' 'C:\t\install.ps1' '-Target "C:\x"'
Assert ($planScript.file -eq 'powershell.exe') 'script 交给 powershell' "script 启动文件不对：$($planScript.file)"
Assert ($planScript.args -match '-File "C:\\t\\install\.ps1" -Target "C:\\x"$') "script 参数完整（$($planScript.args)）" "script 参数不对：$($planScript.args)"
Assert ($planScript.elevate -eq $false) 'script 默认不提权' 'script 默认提权'

$planNsis = Get-InstallerPlan 'nsis' 'C:\t\setup.exe' '/S /D=C:\x'
Assert ($planNsis.file -eq 'C:\t\setup.exe' -and $planNsis.args -eq '/S /D=C:\x') 'nsis 直接跑安装器并原样传参' "nsis 计划不对：$($planNsis.file) / $($planNsis.args)"
Assert ($planNsis.elevate -eq $true) 'nsis 默认需要提权' 'nsis 默认不提权'

# 非法 installerKind 在发命令前就被拦
$rtss = Get-ExtensionEntry 'rtss-shm'
$origKind = [string]$rtss.package.installerKind
$rtss.package.installerKind = 'weird'
$badKind = $false
try { $null = New-ExtensionProvisionSpec $rtss 'oneclick' } catch { $badKind = ($_.Exception.Message -like 'packageInvalid:installerKind*') }
Assert $badKind '未知 installerKind 被配置自检拦截' '未知 installerKind 未被拦截'
$rtss.package.installerKind = $origKind

# ---------- 2. 造包：两个安装脚本（正常退出码 3 / 失败退出码 1） ----------
$work = Join-Path $script:DataDir 'fixture'
New-Item -ItemType Directory -Path $work -Force | Out-Null
Set-Content -LiteralPath (Join-Path $work 'install-ok.ps1') -Value @'
param([string]$Target)
New-Item -ItemType Directory -Path $Target -Force | Out-Null
exit 3
'@ -Encoding UTF8
Set-Content -LiteralPath (Join-Path $work 'install-bad.ps1') -Value @'
param([string]$Target)
exit 1
'@ -Encoding UTF8
$zip = Join-Path $script:DataDir 'pkg.zip'
[void][System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem')
if (Test-Path $zip) { Remove-Item $zip -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($work, $zip)
$zipSha = Get-Sha $zip

$shmName = 'B134_SHM_' + [guid]::NewGuid().ToString('N').Substring(0, 12)
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
$rtss.package.sha256 = $zipSha
$rtss.package.archiveName = 'pkg.zip'
$rtss.package.installerKind = 'script'
$rtss.package.elevateInstall = $false
$rtss.package.requireSignature = $false
$rtss.package.installerSha256 = ''
$rtss.package.processArgs = ''
$rtss.package.processCommand = (Join-Path $env:WINDIR 'System32\where.exe')
$rtss.package.verifyTimeoutMs = 3000
$rtss.shmName = $shmName

function New-Spec([string]$tag) {
    $s = New-ExtensionProvisionSpec $rtss 'oneclick'
    $s.cacheDir = Join-Path $script:DataDir ('cache-' + $tag)
    $s.targetDir = Join-Path $script:DataDir ('target-' + $tag)
    $s.diagDir = Join-Path $script:DataDir 'logs'
    $s.cancelSignal = @{ requested = $false }
    return $s
}

# ---------- 3. 成功码列表生效：退出码 3 被声明为成功 ----------
$s1 = New-Spec 'ok3'
$s1.installerRelative = 'install-ok.ps1'
$s1.installArgs = '-Target "{DIR}"'
$s1.installSuccessCodes = @(3)
$r1 = Invoke-Worker $s1
Assert ($r1.ok -eq $true) "退出码 3 在成功码列表里 → 供应成功（reason=$($r1.reason)）" "成功码未生效：$($r1.reason) $($r1.detail)"

# ---------- 4. 未声明的非零退出码 → installFailed，且完全回滚 ----------
$s2 = New-Spec 'bad1'
$s2.installerRelative = 'install-bad.ps1'
$s2.installArgs = '-Target "{DIR}"'
$s2.installSuccessCodes = @()
$r2 = Invoke-Worker $s2
Assert ($r2.reason -eq 'installFailed') "退出码 1 → installFailed（实际 $($r2.reason)）" "非零退出码没被判失败：$($r2.reason)"
Assert ($r2.detail -match '退出码 1') '失败详情带上真实退出码' "详情没有退出码：$($r2.detail)"
Assert (-not (Test-Path $s2.targetDir)) '安装失败后目标目录已删（完全回滚）' '安装失败后目标目录残留'
Assert (-not (Test-Path (Join-Path $s2.cacheDir 'work-*'))) '解包中间目录已清理' 'work-* 残留'

# ---------- 5. 配置生效验证：写完能读回才算成功 ----------
$s3 = New-Spec 'cfgok'
$s3.installerRelative = 'install-ok.ps1'
$s3.installArgs = '-Target "{DIR}"'
$s3.installSuccessCodes = @(3)
$s3.configFiles = @([pscustomobject]@{
    relative = 'ProfileTemplates\Config'
    entries  = [pscustomobject]@{ Silent = '1'; FramerateLimit = '0' }
    verify   = $true
})
$r3 = Invoke-Worker $s3
Assert ($r3.ok -eq $true) "配置写入并回读一致 → 供应成功（reason=$($r3.reason)）" "配置回读失败：$($r3.reason) $($r3.detail)"
$cfgFile = Join-Path $s3.targetDir 'ProfileTemplates\Config'
Assert (Test-Path $cfgFile) '配置文件已生成' '配置文件不存在'
if (Test-Path $cfgFile) {
    $txt = Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8
    Assert ($txt -match 'Silent=1' -and $txt -match 'FramerateLimit=0') '配置文件内容与注册表一致' "配置内容不对：$txt"
}

# ---------- 6. 配置写不进去 → configureFailed（不让错误延后到「配置没生效」） ----------
$s4 = New-Spec 'cfgfail'
$s4.installerRelative = 'install-ok.ps1'
$s4.installArgs = '-Target "{DIR}"'
$s4.installSuccessCodes = @(3)
$s4.configFiles = @([pscustomobject]@{
    relative = 'ProfileTemplates\Config'
    entries  = [pscustomobject]@{ Silent = '1' }
    verify   = $true
})
# 先把目标目录建成「已存在」并放一个只读配置文件，模拟写入失败
New-Item -ItemType Directory -Path (Join-Path $s4.targetDir 'ProfileTemplates') -Force | Out-Null
$roFile = Join-Path $s4.targetDir 'ProfileTemplates\Config'
Set-Content -LiteralPath $roFile -Value 'Silent=0' -Encoding UTF8
Set-ItemProperty -LiteralPath $roFile -Name IsReadOnly -Value $true
$r4 = Invoke-Worker $s4
Set-ItemProperty -LiteralPath $roFile -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
Assert ($r4.reason -eq 'configureFailed') "配置文件不可写 → configureFailed（实际 $($r4.reason)）" "配置写失败没被识别：$($r4.reason)"

# ---------- 7. 共享内存未就绪：三段事实而不是一句「未就绪」 ----------
$s5 = New-Spec 'shm'
$s5.installerRelative = 'install-ok.ps1'
$s5.installArgs = '-Target "{DIR}"'
$s5.installSuccessCodes = @(3)
$s5.shmName = 'B134_MISSING_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$s5.verifyTimeoutMs = 800
$r5 = Invoke-Worker $s5
Assert ($r5.reason -eq 'shmNotReady') "共享内存等不到 → shmNotReady（实际 $($r5.reason)）" "未就绪原因不对：$($r5.reason)"
Assert ($r5.detail -match 'shm=' -and $r5.detail -match 'process=' -and $r5.detail -match 'frames=') "详情含三项事实（$($r5.detail)）" "详情仍是笼统一句话：$($r5.detail)"
Assert ($r5.detail -match 'shm=no') '如实报告共享内存对象不存在' '共享内存事实不对'

# ---------- 8. 诊断包：失败落盘，含阶段时间线 / 下载源 / 校验结果 ----------
Assert ($r5.diagPath -and (Test-Path $r5.diagPath)) "失败写出诊断包（$($r5.diagPath)）" '没有生成诊断包'
Assert ($r5.detail -match '诊断包：') '失败详情里给出诊断包路径（可直接复制）' '详情没有诊断包路径'
if ($r5.diagPath -and (Test-Path $r5.diagPath)) {
    $diag = Get-Content -LiteralPath $r5.diagPath -Raw -Encoding UTF8
    Assert ($diag -match '阶段时间线') '诊断包含阶段时间线' '诊断包缺时间线'
    Assert ($diag -match '下载源') '诊断包含下载源记录' '诊断包缺下载源'
    Assert ($diag -match '期望 SHA-256') '诊断包含哈希比对结果' '诊断包缺哈希'
    Assert ($diag -match '安装器退出码') '诊断包含安装器退出码' '诊断包缺退出码'
    Assert ($diag -match 'shmNotReady') '诊断包含失败原因' '诊断包缺原因'
}

# ---------- 9. 完全回滚 + 缓存白名单 ----------
Assert (-not (Test-Path $s5.targetDir)) '失败后目标目录已删' '失败后目标目录残留'
Assert (Test-Path (Join-Path $s5.cacheDir 'pkg.zip')) '已验证归档作为缓存保留（白名单例外）' '可信缓存被回滚删掉'

# ---------- 10. 源码契约 ----------
$provSource = Get-Content (Join-Path $root 'src\app\85-ExtensionProvision.ps1') -Raw -Encoding UTF8
foreach ($need in 'Get-InstallerPlan', 'msiexec.exe', 'Get-EntryMap', 'Get-ShmFacts', 'Save-ProvisionDiagnostics', 'installSuccessCodes', "'msi'") {
    Assert ($provSource -match [regex]::Escape($need)) "E3 实现存在：$need" "供应层缺 $need"
}
Assert ($provSource -match "installedPath|\`$targetDir") '回滚边界仍覆盖目标目录' '回滚边界缺失'

$uiJs = Get-Content (Join-Path $root 'ui\js\extensions.js') -Raw -Encoding UTF8
Assert ($uiJs -match 'verifyFailed' -and $uiJs -match 'cancelled') '前端认识新增失败原因（verifyFailed / cancelled）' '前端缺新原因映射'

# ---------- 收尾 ----------
$va.Dispose(); $shm.Dispose()
Get-ChildItem -LiteralPath $script:DataDir -Recurse -File -ErrorAction SilentlyContinue |
    ForEach-Object { try { $_.IsReadOnly = $false } catch { } }
try { Remove-Item -LiteralPath $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }

if ($fail -gt 0) { Write-Host "== B134 失败 $fail 项 ==" -ForegroundColor Red; exit 1 }
Write-Host '== B134 通过 ==' -ForegroundColor Cyan
exit 0
