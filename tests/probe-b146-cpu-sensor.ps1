# B146 CPU 温度与降频候选扩展原型探针
# 验证：① 用户态传感器库（HWiNFO 共享内存）读 CPU 温度/降频原因的语义与 label 匹配；
#       ② 不捆绑驱动、用户自装的授权边界（extensions.json 声明 + 二次授权字段）；
#       ③ 采不到如实 N/A，不返回 0 冒充。
# 只读共享内存；不装驱动、不注入、不改发布资产。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b146-cpu-sensor.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Warn([string]$m) { Write-Host "  ⚠ $m" -ForegroundColor Yellow }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host '== B146 CPU 温度与降频原型探针 ==' -ForegroundColor Cyan

. (Join-Path $root 'src\app\hwinfo-shm.ps1')
Assert ((Get-Command Get-HwinfoSnapshot -ErrorAction SilentlyContinue) -ne $null) 'HWiNFO 读取器已加载' '读取器未加载'

# ---- 合成共享内存：CPU Package 温度 + 降频相关读数 ----
$SENSOR_SIZE = 0x110; $READING_SIZE = 0x15C; $MAGIC = [uint32]0x4857494E
$name = 'B146_' + [guid]::NewGuid().ToString('N').Substring(0, 10)
$sensorOff = 0x2C; $entryOff = $sensorOff + 1 * $SENSOR_SIZE
$total = $entryOff + 4 * $READING_SIZE
$mmf = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($name, [int64]$total)
$va = $mmf.CreateViewAccessor()
$va.Write([int64]0, [uint32]0x4857494E)   # magic
$va.Write([int64]4, [uint32]1); $va.Write([int64]8, [uint32]1)
$va.Write([int64]0x14, [uint32]$sensorOff); $va.Write([int64]0x18, [uint32]$SENSOR_SIZE); $va.Write([int64]0x1C, [uint32]1)
$va.Write([int64]0x20, [uint32]$entryOff); $va.Write([int64]0x24, [uint32]$READING_SIZE); $va.Write([int64]0x28, [uint32]4)
$cb = [Text.Encoding]::ASCII.GetBytes('CPU [#0]: Test')
for ($k = 0; $k -lt $cb.Length; $k++) { $va.Write([int64]($sensorOff + 8 + $k), [byte]$cb[$k]) }
function Add-Reading([int]$i, [int]$type, [string]$label, [string]$unit, [double]$val) {
    $b = $entryOff + $i * $READING_SIZE
    $va.Write([int64]$b, [uint32]$type); $va.Write([int64]($b + 4), [uint32]0)
    $lb = [Text.Encoding]::ASCII.GetBytes($label)
    for ($k = 0; $k -lt $lb.Length; $k++) { $va.Write([int64]($b + 0x0C + $k), [byte]$lb[$k]) }
    $ub = [Text.Encoding]::ASCII.GetBytes($unit)
    for ($k = 0; $k -lt $ub.Length; $k++) { $va.Write([int64]($b + 0x10C + $k), [byte]$ub[$k]) }
    $va.Write([int64]($b + 0x11C), [double]$val)
}
Add-Reading 0 1 'CPU Package' 'C' 71.25
Add-Reading 1 1 'CPU Die (average)' 'C' 68.5
Add-Reading 2 6 'CPU Clock' 'MHz' 4200
Add-Reading 3 7 'CPU Package Power' 'W' 65.0
$snap = Get-HwinfoSnapshot $name
Assert ($snap.ok) "合成传感器结构解析成功（$($snap.readings.Count) reading）" "解析失败：$($snap.reason)"
$pkg = Find-HwinfoReading $snap 'CPU Package' 'C'
Assert ($null -ne $pkg -and [Math]::Abs($pkg.value - 71.25) -lt 0.01) "CPU Package 温度正确（$($pkg.value)°C）" 'CPU 温度读数错误'
$die = Find-HwinfoReading $snap 'CPU Die (average)' 'C'
Assert ($null -ne $die) 'CPU Die 温度可读（多 label 覆盖）' 'CPU Die 项匹配失败'
$missing = Find-HwinfoReading $snap '不存在的传感器'
Assert ($null -eq $missing) '不存在的传感器返回 null（不返回 0）' '缺失项伪造了数值'
$va.Dispose(); $mmf.Dispose()

# ---- 二次授权边界：注册表声明必须明确「用户自装 / 安装需二次授权」----
$reg = Get-Content (Join-Path $root 'extensions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$cpu = @($reg.extensions | Where-Object { $_.id -eq 'cpu-sensor' })[0]
Assert ($null -ne $cpu -and $cpu.available -eq $false) 'cpu-sensor 仍为 available=false（原型不改发布资产）' "注册表状态异常：$($cpu.available)"
Assert ($cpu.depends -match '用户态传感器库' -and $cpu.permission -match '二次授权') '注册表明确「用户自装 + 二次授权」边界' "边界声明不足：$($cpu.depends) / $($cpu.permission)"
Assert (-not $cpu.package) '未捆绑传感器组件（package 为空）' 'cpu-sensor 意外声明了随包组件'

# ---- 真实探测（本机未运行 HWiNFO 时如实记录）----
$real = Get-HwinfoSnapshot
if ($real.ok) {
    $rp = Find-HwinfoReading $real 'CPU Package'
    if ($rp) { Ok "真机 CPU Package = $($rp.value)°C" } else { Warn '真机共享内存可读但无 CPU Package 项' }
} else { Warn "本机 HWiNFO 共享内存不可读（$($real.reason)）——需用户自装并开启共享内存" }

Write-Host '== B146 通过 ==' -ForegroundColor Cyan
if ($fail -gt 0) { Write-Host ("失败断言 $fail 项") -ForegroundColor Red; exit 1 }
exit 0
