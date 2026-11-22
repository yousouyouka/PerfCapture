# B147 HWiNFO 扩展端到端探针：合成 HWiNFO 共享内存，驱动真实宿主状态机走完
# 安装（依赖探测）→ 启用（数据源仲裁）→ 读取帧快照 → 关闭（回退 presentmon），
# 并验证 HWiNFO 未开/共享内存未启用时如实拒绝、不伪造数据、不改发布资产。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b147-hwinfo-extension.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host '== B147 HWiNFO 扩展端到端探针 ==' -ForegroundColor Cyan

# ---------- stub 宿主依赖 ----------
$script:Root = $root
$script:DataDir = Join-Path $env:TEMP ('PerfCapture-B147-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:Ui = New-Object System.Collections.ArrayList
function Write-AppLog([string]$text, [string]$lvl = 'INFO') { }
function Send-ToUi($p) { [void]$script:Ui.Add($p) }
function Save-Config { }
$script:Cfg = @{ extensions = @{} }
$script:ActiveFpsSource = 'presentmon'
$script:FakeHwinfoProc = $false
function Get-Process { param($Id, $Name) if ($Name -match 'HWiNFO' -and $script:FakeHwinfoProc) { return [pscustomobject]@{ Id = 4242; ProcessName = 'HWiNFO64'; Path = 'C://Program Files\HWiNFO64\HWiNFO64.exe' } }; return $null }
. (Join-Path $root 'src\app\rtss-shm.ps1')
. (Join-Path $root 'src\app\hwinfo-shm.ps1')
. (Join-Path $root 'src\app\80-Extensions.ps1')

# 注册表实测（确认 hwinfo-shm 已发布且声明 hwinfo 读取器）
$regEntry = Get-ExtensionEntry 'hwinfo-shm'
Assert ($null -ne $regEntry -and $regEntry.available) 'hwinfo-shm 已发布（available=true）' "注册表未发布：$($regEntry.available)"
Assert ($regEntry.shmReader -eq 'hwinfo') '读取器声明为 hwinfo' "读取器错误：$($regEntry.shmReader)"
Assert ($regEntry.mode -eq 'external-shm' -and -not $regEntry.package) '非托管外部服务型（不捆绑组件）' '条目类型错误'
$rtssEntry = Get-ExtensionEntry 'rtss-shm'
Assert ($rtssEntry.shmReader -eq 'rtss') 'RTSS 仍声明 rtss 读取器（兼容未被破坏）' "RTSS 读取器错误：$($rtssEntry.shmReader)"

# ---------- 合成共享内存 ----------
$SENSOR_SIZE = 0x110; $READING_SIZE = 0x15C
$shmName = 'B147_' + [guid]::NewGuid().ToString('N').Substring(0, 10)
$sensorOff = 0x2C; $entryOff = $sensorOff + $SENSOR_SIZE
$total = $entryOff + 3 * $READING_SIZE
$mmf = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($shmName, [int64]$total)
$va = $mmf.CreateViewAccessor()
$va.Write([int64]0, [uint32]0x4857494E); $va.Write([int64]4, [uint32]1); $va.Write([int64]8, [uint32]1)
$va.Write([int64]0x14, [uint32]$sensorOff); $va.Write([int64]0x18, [uint32]$SENSOR_SIZE); $va.Write([int64]0x1C, [uint32]1)
$va.Write([int64]0x20, [uint32]$entryOff); $va.Write([int64]0x24, [uint32]$READING_SIZE); $va.Write([int64]0x28, [uint32]3)
$cb = [Text.Encoding]::ASCII.GetBytes('CPU [#0]: Test')
for ($k = 0; $k -lt $cb.Length; $k++) { $va.Write([int64]($sensorOff + 8 + $k), [byte]$cb[$k]) }
function Add-Reading([int]$i, [int]$type, [string]$label, [string]$unit, [double]$val) {
    $b = $entryOff + $i * $READING_SIZE
    $va.Write([int64]$b, [uint32]$type); $va.Write([int64]($b+4), [uint32]0)
    $lb = [Text.Encoding]::ASCII.GetBytes($label)
    for ($k=0; $k -lt $lb.Length; $k++) { $va.Write([int64]($b+0x0C+$k), [byte]$lb[$k]) }
    $ub = [Text.Encoding]::ASCII.GetBytes($unit)
    for ($k=0; $k -lt $ub.Length; $k++) { $va.Write([int64]($b+0x10C+$k), [byte]$ub[$k]) }
    $va.Write([int64]($b+0x11C), [double]$val)
}
Add-Reading 0 1 'CPU Package' 'C' 62.0
Add-Reading 1 7 'FPS' 'fps' 118.5
Add-Reading 2 7 'Frame Time' 'ms' 8.44

# 把条目指向合成对象（注册表 shmName 保持真实值不变，只在内存副本上改）
$regEntry.shmName = $shmName

# ---------- 1. 未启动时如实拒绝 ----------
$dep0 = Test-ExtensionDependency $regEntry
Assert (-not $dep0.ok) 'HWiNFO 未运行时依赖探测失败（不假装成功）' "依赖误判成功：$($dep0.ok)"

# ---------- 2. 共享内存就绪 → 安装成功 ----------
$script:FakeHwinfoProc = $true
$installed = Install-ExtensionCore 'hwinfo-shm'
Assert ($installed) '合成共享内存就绪时安装成功' '安装失败'
Assert ((Get-ExtensionPersistState 'hwinfo-shm') -eq 'installed') '持久化状态为 installed' "状态错误：$(Get-ExtensionPersistState 'hwinfo-shm')"

# ---------- 3. 启用 → 数据源切到 hwinfo ----------
$enabled = Enable-ExtensionCore 'hwinfo-shm'
Assert ($enabled) '启用成功' '启用失败'
Assert ($script:ActiveFpsSource -eq 'hwinfo-shm') '数据源已切到 hwinfo-shm' "数据源错误：$($script:ActiveFpsSource)"
Assert ((Get-ExtensionStateFor $regEntry) -eq 'enabled') '状态机判为 enabled' "状态错误：$(Get-ExtensionStateFor $regEntry)"

# ---------- 4. 帧快照契约（与 RTSS 同字段，供采样侧直接消费）----------
$snap = Get-ActiveExtensionFps
Assert ($null -ne $snap -and $snap.ok) '数据源帧快照读取成功' "快照读取失败：$($snap.reason)"
Assert ([Math]::Abs($snap.fps - 118.5) -lt 0.01) "FPS 正确（$($snap.fps)）" "FPS 错误：$($snap.fps)"
Assert ([Math]::Abs($snap.frameTimeUs - 8440) -lt 1) "帧时间换算正确（$($snap.frameTimeUs) us）" "帧时间错误：$($snap.frameTimeUs)"
Assert ($snap.source -eq 'hwinfo-shm') '快照标记来源为 hwinfo-shm' "来源错误：$($snap.source)"
Assert ($null -eq $snap.fpsLow1) '没有 1% Low 时不伪造（如实为 null）' '伪造了 1% Low'

# ---------- 5. 数据源仲裁：坏源拒绝、基线保持 ----------
$script:ActiveFpsSource = 'presentmon'
$accepted = Set-FpsSource 'hwinfo-shm'
Assert ($accepted) 'enabled 状态可被选为数据源' '数据源仲裁误拒'
$va.Dispose(); $mmf.Dispose()
$afterClose = Get-ExtensionStateFor $regEntry
Assert ($afterClose -eq 'failed') 'HWiNFO 关闭后状态如实转 failed（不谎报可用）' "状态错误：$afterClose"

# ---------- 6. 关闭 → 回退零注入基线 ----------
Set-ExtensionPersistState 'hwinfo-shm' 'enabled' ''
$script:ActiveFpsSource = 'hwinfo-shm'
$disabled = Disable-ExtensionCore 'hwinfo-shm'
Assert ($disabled) '关闭成功' '关闭失败'
Assert ($script:ActiveFpsSource -eq 'presentmon') '关闭后数据源回退 presentmon' "数据源未回退：$($script:ActiveFpsSource)"
Assert ((Get-ExtensionPersistState 'hwinfo-shm') -eq 'installed') '关闭后保留已装状态（不卸载）' "状态错误：$(Get-ExtensionPersistState 'hwinfo-shm')"

# ---------- 7. 发布资产未被原型改动 ----------
$reg = Get-Content (Join-Path $root 'extensions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$hw = @($reg.extensions | Where-Object { $_.id -eq 'hwinfo-shm' })[0]
Assert ($hw.available -eq $true -and $hw.shmName -eq 'Global\HWiNFO_SENS_SM2') '注册表真实值未被探针改写' '探针污染了注册表文件'

Write-Host '== B147 通过 ==' -ForegroundColor Cyan
if ($fail -gt 0) { Write-Host ("失败断言 $fail 项") -ForegroundColor Red; exit 1 }
exit 0
