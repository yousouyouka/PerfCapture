# HWiNFO 共享内存读取器（原型，未接入扩展中心；available=false 不改）
# 数据来源：HWiNFO 在「设置 → HWiNFO Gadget → 激活共享内存支持」后发布的对象 Global\HWiNFO_SENS_SM2。
# 结构来自社区逆向（namazso/hwinfoshmem，GPL）与官方 Shared Memory Viewer 对照，
# 本实现只读、不写、不注入；按 pack(1) 手工读字节，避开 PowerShell Add-Type 的对齐差异。
#
# 铁律（继承 rtss-shm.ps1）：采不到一律 N/A（ok=$false + reason），绝不返回 0 冒充真实值；
# 共享内存存在但没有任何传感器记录 = 待机/未启用共享内存，不算故障；
# 结构签名/版本不符 = 结构不兼容，如实报 badSignature/versionMismatch。

$script:HwinfoShmSource = @'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class HwinfoNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr OpenFileMapping(uint dwDesiredAccess, bool bInheritHandle, string lpName);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr MapViewOfFile(IntPtr hFileMappingObject, uint dwDesiredAccess,
        uint dwFileOffsetHigh, uint dwFileOffsetLow, UIntPtr dwNumberOfBytesToMap);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool UnmapViewOfFile(IntPtr lpBaseAddress);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
    [DllImport("kernel32.dll")]
    public static extern uint GetLastError();
}
"@ -ErrorAction SilentlyContinue

# 结构常量（pack(1)，与 C/Go/Node 社区实现一致）
$HwinfoHeaderSize  = 0x2C   # 44
$HwinfoSensorSize  = 0x110  # 272
$HwinfoReadingSize = 0x15C  # 348
$HwinfoMagic       = [uint32]0x4857494E   # 'HWiS'（内存字节序 'HWiS' -> uint 0x4857494E）

# PS 5.1 下 Marshal.Copy(IntPtr, int, byte[], int, int) 重载解析不稳，
# 定长字段改走 ReadInt32/ReadInt64；字符串仍用 Copy，并把 IntPtr 偏移先加好。
function Read-HwinfoU32([IntPtr]$base, [int]$off) {
    $raw = [Runtime.InteropServices.Marshal]::ReadInt32($base, $off)
    return [BitConverter]::ToUInt32([BitConverter]::GetBytes($raw), 0)
}
function Read-HwinfoI64([IntPtr]$base, [int]$off) {
    return [Runtime.InteropServices.Marshal]::ReadInt64($base, $off)
}
function Read-HwinfoF64([IntPtr]$base, [int]$off) {
    $bits = [Runtime.InteropServices.Marshal]::ReadInt64($base, $off)
    return [BitConverter]::Int64BitsToDouble($bits)
}
function Read-HwinfoStr([IntPtr]$base, [int]$off, [int]$max = 128) {
    $b = New-Object byte[] $max
    $ptr = [IntPtr]($base.ToInt64() + $off)
    [Runtime.InteropServices.Marshal]::Copy($ptr, $b, 0, $max)
    $n = 0
    while ($n -lt $max -and $b[$n] -ne 0) { $n++ }
    if ($n -eq 0) { return '' }
    return [Text.Encoding]::ASCII.GetString($b, 0, $n)
}

function Close-HwinfoShm($h) {
    if ($null -eq $h) { return }
    if ($h.view -ne [IntPtr]::Zero) { try { [void][HwinfoNative]::UnmapViewOfFile($h.view) } catch { } }
    if ($h.map -ne [IntPtr]::Zero) { try { [void][HwinfoNative]::CloseHandle($h.map) } catch { } }
}

function Open-HwinfoShm([string]$Name = 'Global\HWiNFO_SENS_SM2') {
    $map = [HwinfoNative]::OpenFileMapping(0x0004, $false, $Name)   # FILE_MAP_READ
    if ($map -eq [IntPtr]::Zero) {
        return [pscustomobject]@{ ok = $false; reason = 'shmNotFound'; map = [IntPtr]::Zero; view = [IntPtr]::Zero; size = 0 }
    }
    $view = [HwinfoNative]::MapViewOfFile($map, 0x0004, 0, 0, [UIntPtr]::Zero)
    if ($view -eq [IntPtr]::Zero) {
        [void][HwinfoNative]::CloseHandle($map)
        return [pscustomobject]@{ ok = $false; reason = 'shmOpenFailed'; map = [IntPtr]::Zero; view = [IntPtr]::Zero; size = 0 }
    }
    $h = [pscustomobject]@{ ok = $true; reason = ''; map = $map; view = $view; size = 0 }
    $magic = Read-HwinfoU32 $view 0
    if ($magic -ne $HwinfoMagic) { Close-HwinfoShm $h; return [pscustomobject]@{ ok = $false; reason = 'badSignature'; map = [IntPtr]::Zero; view = [IntPtr]::Zero; size = 0 } }
    $ver = Read-HwinfoU32 $view 4
    if ($ver -ne 1) { Close-HwinfoShm $h; return [pscustomobject]@{ ok = $false; reason = 'versionMismatch'; map = [IntPtr]::Zero; view = [IntPtr]::Zero; size = 0 } }
    $h.size = [int](Read-HwinfoU32 $view 0x20)   # entry_section_offset：作为最小有效长度下界
    return $h
}

# 读取全部传感器读数。返回 { ok; reason; sensors; readings; lastUpdate }
# label 匹配不区分大小写，支持中文用户改名（labelUser）。
function Get-HwinfoSnapshot([string]$Name = 'Global\HWiNFO_SENS_SM2') {
    $h = Open-HwinfoShm $Name
    if (-not $h.ok) {
        return [pscustomobject]@{ ok = $false; reason = $h.reason; sensors = @(); readings = @(); lastUpdate = [DateTime]::MinValue }
    }
    try {
        $v = $h.view
        $sensorOff  = [int](Read-HwinfoU32 $v 0x14)
        $sensorSize = [int](Read-HwinfoU32 $v 0x18)
        $sensorCnt  = [int](Read-HwinfoU32 $v 0x1C)
        $entryOff   = [int](Read-HwinfoU32 $v 0x20)
        $entrySize  = [int](Read-HwinfoU32 $v 0x24)
        $entryCnt   = [int](Read-HwinfoU32 $v 0x28)
        $lastUtc    = Read-HwinfoI64 $v 0x0C
        $lastUpdate = if ($lastUtc -gt 0) { [DateTimeOffset]::FromUnixTimeSeconds($lastUtc).LocalDateTime } else { [DateTime]::MinValue }

        # 结构自检：尺寸/计数明显越界一律拒绝，不拿乱码当传感器值。
        if ($sensorSize -lt $HwinfoSensorSize -or $entrySize -lt $HwinfoReadingSize -or
            $sensorCnt -lt 0 -or $sensorCnt -gt 4096 -or $entryCnt -lt 0 -or $entryCnt -gt 65536 -or
            $sensorOff -lt 0 -or $entryOff -lt 0) {
            return [pscustomobject]@{ ok = $false; reason = 'badLayout'; sensors = @(); readings = @(); lastUpdate = $lastUpdate }
        }

        $sensors = @()
        for ($i = 0; $i -lt $sensorCnt; $i++) {
            $b = $sensorOff + $i * $sensorSize
            $sensors += [pscustomobject]@{
                index = $i
                id = [int](Read-HwinfoU32 $v $b)
                instance = [int](Read-HwinfoU32 $v ($b + 4))
                nameOriginal = Read-HwinfoStr $v ($b + 8) 128
                nameUser = Read-HwinfoStr $v ($b + 0x88) 128
            }
        }
        $readings = @()
        for ($i = 0; $i -lt $entryCnt; $i++) {
            $b = $entryOff + $i * $entrySize
            $type = [int](Read-HwinfoU32 $v $b)
            $sIdx = [int](Read-HwinfoU32 $v ($b + 4))
            $readings += [pscustomobject]@{
                index = $i
                type = $type
                typeName = switch ($type) { 0 { 'none' } 1 { 'temperature' } 2 { 'voltage' } 3 { 'fan' } 4 { 'current' } 5 { 'power' } 6 { 'clock' } 7 { 'usage' } default { 'other' } }
                sensorIndex = $sIdx
                id = [int](Read-HwinfoU32 $v ($b + 8))
                labelOriginal = Read-HwinfoStr $v ($b + 0x0C) 128
                labelUser = Read-HwinfoStr $v ($b + 0x8C) 128
                unit = Read-HwinfoStr $v ($b + 0x10C) 16
                value = Read-HwinfoF64 $v ($b + 0x11C)
                valueMin = Read-HwinfoF64 $v ($b + 0x124)
                valueMax = Read-HwinfoF64 $v ($b + 0x12C)
                valueAvg = Read-HwinfoF64 $v ($b + 0x134)
            }
        }
        # 共享内存对象在，但没有任何读数 = HWiNFO 未开启共享内存发布（待机），不是故障。
        $reason = if ($readings.Count -eq 0) { 'noReadings' } else { '' }
        return [pscustomobject]@{
            ok = ($readings.Count -gt 0); reason = $reason
            sensors = $sensors; readings = $readings; lastUpdate = $lastUpdate
        }
    } finally { Close-HwinfoShm $h }
}

# 找读数：按 label（原名或用户改名）与单位匹配，避免硬编码 sensor index（布局会随版本漂移）。
function Find-HwinfoReading($Snapshot, [string]$Label, [string]$Unit = '') {
    if (-not $Snapshot -or -not $Snapshot.ok) { return $null }
    $needle = $Label.ToLowerInvariant()
    foreach ($r in $Snapshot.readings) {
        $hit = $r.labelOriginal.ToLowerInvariant() -eq $needle -or $r.labelUser.ToLowerInvariant() -eq $needle
        if ($hit -and (-not $Unit -or $r.unit -eq $Unit)) { return $r }
    }
    return $null
}

# 帧率项：HWiNFO 的「FPS」reading 常见 label 有 'FPS' / 'Frame Rate' / 'Current Framerate'，
# 来源可能是 RTSS 或游戏内统计——本函数只负责取值，源归属由上层结合 detect 判断。
function Get-HwinfoFps($Snapshot) {
    if (-not $Snapshot -or -not $Snapshot.ok) { return $null }
    foreach ($label in 'FPS', 'Frame Rate', 'Framerate', 'Current Framerate') {
        $r = Find-HwinfoReading $Snapshot $label
        if ($r -and $r.value -gt 0) { return $r }
    }
    return $null
}

# 帧快照：与 RTSS 读取器同契约，供 35-Metrics 数据源仲裁直接消费。
# 帧时间：HWiNFO 若暴露 'Frame Time' / 'Frametime'（ms）就换算成微秒；没有就由 FPS 反推，
# 并在 source 字段标注推导来源——不拿推导值冒充 HWiNFO 原生测量。
function Get-HwinfoFrameSnapshot([string]$Name = 'Global\HWiNFO_SENS_SM2') {
    $res = [pscustomobject]@{
        ok = $false; reason = ''; detail = ''; fps = $null; fpsLow1 = $null
        frameTimeUs = $null; sampleCount = 0; processName = ''; version = ''
        source = 'hwinfo-shm'; at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $snap = Get-HwinfoSnapshot $Name
    if (-not $snap.ok) { $res.reason = $snap.reason; return $res }
    $fps = Get-HwinfoFps $snap
    if (-not $fps) {
        # 共享内存可读但没在统计游戏：待机（noFrames），不是故障。
        $res.reason = 'noFrames'
        $res.sampleCount = $snap.readings.Count
        return $res
    }
    $res.ok = $true
    $res.fps = [math]::Round([double]$fps.value, 2)
    $res.sampleCount = $snap.readings.Count
    $ftUs = $null
    foreach ($label in 'Frame Time', 'Frametime', 'Frame time') {
        $r = Find-HwinfoReading $snap $label
        if ($r -and $r.value -gt 0) { $ftUs = [math]::Round([double]$r.value * 1000.0, 1); break }
    }
    if ($null -eq $ftUs -and $res.fps -gt 0) { $ftUs = [math]::Round(1000000.0 / [double]$res.fps, 1) }
    $res.frameTimeUs = $ftUs
    $res.detail = if ($ftUs) { 'frameTime=derived-or-reading' } else { '' }
    return $res
}
'@

# 本文件被 dot-source 时把源码字符串保存下来，供后台 worker / 探针注入（与 rtss-shm.ps1 同模式）。
$script:HwinfoReaderSource = $script:HwinfoShmSource
if (-not (Get-Command Get-HwinfoSnapshot -ErrorAction SilentlyContinue)) {
    . ([scriptblock]::Create($script:HwinfoShmSource))
}
