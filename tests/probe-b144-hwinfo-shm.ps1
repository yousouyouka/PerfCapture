# B144 HWiNFO 共享内存读数原型探针（候选扩展：hwinfo-shm）
# ① 合成 HWiNFO_SENS_SM2 结构（签名/版本/sensor/reading），验证解析、语义与失败细分；
# ② 对真实共享内存对象做一次探测（本机 HWiNFO 未运行时如实记 shmNotFound，不算失败）。
# 只读、不写、不注入；采不到一律 N/A，绝不返回 0 冒充。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b144-hwinfo-shm.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Warn([string]$m) { Write-Host "  ⚠ $m" -ForegroundColor Yellow }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host '== B144 HWiNFO 共享内存读数原型探针 ==' -ForegroundColor Cyan

. (Join-Path $root 'src\app\hwinfo-shm.ps1')
Assert ((Get-Command Get-HwinfoSnapshot -ErrorAction SilentlyContinue) -ne $null) '读取器已加载（Get-HwinfoSnapshot）' '读取器未加载'
Assert ($script:HwinfoReaderSource -match 'OpenFileMapping') '读取器源码可注入后台 worker' '缺可注入源码'

# ---- 合成共享内存工具 ----
$MAGIC = [uint32]0x4857494E
$SENSOR_SIZE = 0x110
$READING_SIZE = 0x15C
function New-HwinfoShm([string]$name, [int]$sensorCnt, [int]$readingCnt) {
    $sensorOff = 0x2C
    $entryOff = $sensorOff + $sensorCnt * $SENSOR_SIZE
    $total = $entryOff + $readingCnt * $READING_SIZE
    $mmf = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($name, [int64]$total)
    $va = $mmf.CreateViewAccessor()
    function W32($o, [uint32]$v) { $va.Write([int64]$o, [uint32]$v) }
    function WI64($o, [int64]$v) { $va.Write([int64]$o, [int64]$v) }
    W32 0 $MAGIC; W32 4 1; W32 8 1
    WI64 0x0C ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    W32 0x14 $sensorOff; W32 0x18 $SENSOR_SIZE; W32 0x1C $sensorCnt
    W32 0x20 $entryOff; W32 0x24 $READING_SIZE; W32 0x28 $readingCnt
    return @{ mmf = $mmf; va = $va; entryOff = $entryOff }
}
function Set-Sensor($h, [int]$i, [int]$id, [string]$name) {
    $b = 0x2C + $i * $SENSOR_SIZE
    $h.va.Write([int64]$b, [uint32]$id)
    $bytes = [Text.Encoding]::ASCII.GetBytes($name)
    for ($k = 0; $k -lt $bytes.Length -and $k -lt 127; $k++) { $h.va.Write([int64]($b + 8 + $k), [byte]$bytes[$k]) }
}
function Set-Reading($h, [int]$i, [int]$type, [int]$sensorIdx, [string]$label, [string]$unit, [double]$value) {
    $b = $h.entryOff + $i * $READING_SIZE
    $h.va.Write([int64]$b, [uint32]$type)
    $h.va.Write([int64]($b + 4), [uint32]$sensorIdx)
    $bytes = [Text.Encoding]::ASCII.GetBytes($label)
    for ($k = 0; $k -lt $bytes.Length -and $k -lt 127; $k++) { $h.va.Write([int64]($b + 0x0C + $k), [byte]$bytes[$k]) }
    $ub = [Text.Encoding]::ASCII.GetBytes($unit)
    for ($k = 0; $k -lt $ub.Length -and $k -lt 15; $k++) { $h.va.Write([int64]($b + 0x10C + $k), [byte]$ub[$k]) }
    $h.va.Write([int64]($b + 0x11C), [double]$value)
}
function Close-Shm($h) { $h.va.Dispose(); $h.mmf.Dispose() }
function New-Name { 'B144_' + [guid]::NewGuid().ToString('N').Substring(0, 10) }

# ---- 1. 正常解析：CPU 温度 + FPS（两种语义）----
$n1 = New-Name
$h1 = New-HwinfoShm $n1 2 3
Set-Sensor $h1 0 1 'CPU [#0]: Test CPU'
Set-Sensor $h1 1 2 'GPU [#0]: Test GPU'
Set-Reading $h1 0 1 0 'CPU Package' '°C' 63.5
Set-Reading $h1 1 7 1 'GPU Core' '%' 47.0
Set-Reading $h1 2 7 0 'FPS' 'fps' 142.75
$s1 = Get-HwinfoSnapshot $n1
Assert ($s1.ok) "正常结构解析成功（$($s1.sensors.Count) sensor / $($s1.readings.Count) reading）" "正常结构解析失败：$($s1.reason)"
Assert ($s1.sensors[0].nameOriginal -like 'CPU*') "sensor 名称解析正确（$($s1.sensors[0].nameOriginal)）" 'sensor 名称解析错误'
$temp = Find-HwinfoReading $s1 'CPU Package'
Assert ($null -ne $temp -and [Math]::Abs($temp.value - 63.5) -lt 0.01) "温度读数正确（$($temp.value)°C）" '温度读数错误'
$fps = Get-HwinfoFps $s1
Assert ($null -ne $fps -and [Math]::Abs($fps.value - 142.75) -lt 0.01) "FPS 读数正确（$($fps.value) fps）" 'FPS 读数错误'
Close-Shm $h1

# ---- 2. 失败细分：签名 / 版本 / 布局 / 对象不存在 ----
$n2 = New-Name
$h2 = New-HwinfoShm $n2 1 1
$h2.va.Write([int64]0, [uint32]3735928559)
$s2 = Get-HwinfoSnapshot $n2
Assert ($s2.reason -eq 'badSignature') "签名不符报 badSignature（$($s2.reason)）" "签名判定错误：$($s2.reason)"
Close-Shm $h2

$n3 = New-Name
$h3 = New-HwinfoShm $n3 1 1
$h3.va.Write([int64]4, [uint32]99)
$s3 = Get-HwinfoSnapshot $n3
Assert ($s3.reason -eq 'versionMismatch') "版本不符报 versionMismatch（$($s3.reason)）" "版本判定错误：$($s3.reason)"
Close-Shm $h3

$s4 = Get-HwinfoSnapshot ('B144_no_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Assert ($s4.reason -eq 'shmNotFound' -and -not $s4.ok) '对象不存在报 shmNotFound（不返回 0）' "缺失判定错误：$($s4.reason)"

# ---- 3. 待机：对象在但无读数 ----
$n5 = New-Name
$h5 = New-HwinfoShm $n5 0 0
$s5 = Get-HwinfoSnapshot $n5
Assert (-not $s5.ok -and $s5.reason -eq 'noReadings') '空读数报 noReadings（待机，不是故障）' "空读数判定错误：$($s5.ok)/$($s5.reason)"
Close-Shm $h5

# ---- 4. 用户改名 labelUser 也能匹配 ----
$n6 = New-Name
$h6 = New-HwinfoShm $n6 1 1
Set-Sensor $h6 0 1 'CPU'
Set-Reading $h6 0 1 0 'CPU Package' 'C' 55.25
$b6 = $h6.entryOff + 0x8C
$u6 = [Text.Encoding]::ASCII.GetBytes('MyRenamedCPU')
for ($k = 0; $k -lt $u6.Length; $k++) { $h6.va.Write([int64]($b6 + $k), [byte]$u6[$k]) }
$s6 = Get-HwinfoSnapshot $n6
$renamed = Find-HwinfoReading $s6 'MyRenamedCPU'
Assert ($null -ne $renamed -and $renamed.value -eq 55.25) '用户改名的 label 也能匹配（ASCII 段）' '改名 label 匹配失败'
Close-Shm $h6

# ---- 5. 真实对象探测（本机 HWiNFO 未运行时如实记录）----
$real = Get-HwinfoSnapshot 'Global\HWiNFO_SENS_SM2'
if ($real.ok) {
    Ok "本机 HWiNFO 共享内存可读：$($real.sensors.Count) sensor / $($real.readings.Count) reading"
    $rfps = Get-HwinfoFps $real
    if ($rfps) { Ok "真机 FPS 项：$($rfps.labelOriginal) = $($rfps.value) $($rfps.unit)" }
    else { Warn '真机共享内存可读，但没有 FPS 项（HWiNFO 未必统计帧率，需用户开启对应传感器）' }
} else {
    Warn "本机 HWiNFO 共享内存不可读（$($real.reason)）——HWiNFO 未运行或未开启共享内存支持"
    Assert ($real.reason -in @('shmNotFound', 'shmOpenFailed', 'badSignature', 'versionMismatch', 'badLayout')) '真实探测给出细分原因（非 0、非伪造）' "真实探测原因异常：$($real.reason)"
}

Write-Host '== B144 通过 ==' -ForegroundColor Cyan
if ($fail -gt 0) { Write-Host ("失败断言 $fail 项") -ForegroundColor Red; exit 1 }
exit 0
