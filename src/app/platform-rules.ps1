# 平台覆盖规则（实现处，唯一事实来源见《数据源与平台覆盖规则.md》）
#
# 设计原则：
#   - 本文件不依赖任何其它宿主模块，可被采样 runspace / 采集引擎 / 探针单独 dot-source。
#   - 只做「探测 + 判定」，不做日志、不发 UI 消息；失败一律返回 reason 码，由上层决定怎么显示。
#   - 探测结果缓存 60 s：CIM 查询在冷启动时约 30–80 ms，不能每帧都问。
#
# 覆盖承诺（改动前先改规则文档）：
#   OS  : Windows 10 1809+ / Windows 11 (x64)
#   CPU : Intel (GenuineIntel) / AMD (AuthenticAMD)
#   GPU : NVIDIA（nvml.dll / nvidia-smi）
#   温度: 仅联想固件通道（见 vendor-sensor.ps1）

$script:PlatformMinBuild = 17763          # Windows 10 1809
$script:PlatformProfileCache = $null
$script:PlatformProfileAt = [datetime]::MinValue

function Get-CpuVendorName([string]$Manufacturer, [string]$Name) {
    $m = ([string]$Manufacturer).Trim()
    if ($m -eq 'GenuineIntel') { return 'intel' }
    if ($m -eq 'AuthenticAMD') { return 'amd' }
    # 少数虚拟化/兼容层不给 Manufacturer，再按型号名兜底（只认明确前缀）
    $n = ([string]$Name).Trim()
    if ($n -match '^(Intel|第\s*\d+\s*代\s*Intel|12th|13th|14th)') { return 'intel' }
    if ($n -match '^(AMD|Ryzen|EPYC|Threadripper)') { return 'amd' }
    return 'other'
}

function Get-GpuVendorName([string]$Name) {
    $n = ([string]$Name).Trim()
    if ($n -match '(?i)^NVIDIA') { return 'nvidia' }
    if ($n -match '(?i)^AMD|Radeon') { return 'amd' }
    if ($n -match '(?i)^Intel') { return 'intel' }
    # 虚拟显示器 / 远程桌面适配器不算显卡
    if ($n -match '(?i)Virtual|Remote|Basic Display|MuMu|GameViewer|Parsec|Sunshine') { return 'virtual' }
    return 'other'
}

# 返回平台画像（ordered hashtable，便于直接进 summary / JSON）。
# -Fresh 跳过缓存：探针与「用户改了硬件/换机」场景使用。
function Get-PlatformProfile([switch]$Fresh) {
    if (-not $Fresh -and $script:PlatformProfileCache -and ((Get-Date) - $script:PlatformProfileAt).TotalSeconds -lt 60) {
        return $script:PlatformProfileCache
    }
    $p = [ordered]@{
        osOk = $false; osName = ''; osBuild = 0; osArch = ''
        cpuVendor = 'other'; cpuModel = ''; cpuCores = 0; cpuBaseMhz = 0
        gpuVendor = 'other'; gpuModel = ''
        systemVendor = ''; systemModel = ''; bios = ''
        supported = $false; reasons = @()
    }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $p.osBuild = [int]$os.BuildNumber
        $p.osName = ([string]$os.Caption).Trim()
        $p.osArch = [string]$os.OSArchitecture
    } catch {
        $p.osBuild = [Environment]::OSVersion.Version.Build
        $p.osName = [Environment]::OSVersion.VersionString
        $p.osArch = if ([Environment]::Is64BitOperatingSystem) { '64-bit' } else { '32-bit' }
    }
    # ARM64 上 PresentMon / nvidia-smi 的假设都不成立，规则里明确不支持
    $isArm = $false
    try { $isArm = ($p.osArch -match 'ARM') -or ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') } catch { }
    $p.osOk = ($p.osBuild -ge $script:PlatformMinBuild) -and (-not $isArm)
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cpu) {
            $p.cpuVendor = Get-CpuVendorName $cpu.Manufacturer $cpu.Name
            $p.cpuModel = ([string]$cpu.Name).Trim()
            $p.cpuCores = [int]$cpu.NumberOfCores
            $p.cpuBaseMhz = [int]$cpu.MaxClockSpeed
        }
    } catch { }
    try {
        $vcs = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
        $nv = @($vcs | Where-Object { (Get-GpuVendorName $_.Name) -eq 'nvidia' })
        if ($nv.Count -gt 0) {
            $p.gpuVendor = 'nvidia'
            # 多张 NVIDIA 时取显存最大的那张（Optimus 机器上可能有核显排在前面）
            # AdapterRAM 是 uint32，超过 2 GB 的卡会溢出 Int32，必须按 double 排
            $best = $nv | Sort-Object { [double]$_.AdapterRAM } -Descending | Select-Object -First 1
            $p.gpuModel = ([string]$best.Name).Trim()
        } elseif ($vcs.Count -gt 0) {
            $pick = $vcs | Where-Object { (Get-GpuVendorName $_.Name) -ne 'virtual' } | Select-Object -First 1
            if (-not $pick) { $pick = $vcs[0] }
            $p.gpuVendor = Get-GpuVendorName $pick.Name
            $p.gpuModel = ([string]$pick.Name).Trim()
        }
    } catch { }
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $p.systemVendor = ([string]$cs.Manufacturer).Trim()
        $p.systemModel = ([string]$cs.Model).Trim()
    } catch { }
    try {
        $b = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        $p.bios = (([string]$b.SMBIOSBIOSVersion).Trim() + ' / ' + ([string]$b.ReleaseDate).Trim()).Trim(' /')
    } catch { }

    $reasons = New-Object System.Collections.ArrayList
    if (-not $p.osOk) {
        if ($isArm) { [void]$reasons.Add('unsupportedArch') }
        elseif ($p.osBuild -lt $script:PlatformMinBuild) { [void]$reasons.Add('unsupportedOsBuild') }
        else { [void]$reasons.Add('unsupportedOs') }
    }
    if ($p.cpuVendor -notin @('intel', 'amd')) { [void]$reasons.Add('unsupportedCpu') }
    if ($p.gpuVendor -ne 'nvidia') { [void]$reasons.Add('unsupportedGpu') }
    $p.reasons = @($reasons)
    $p.supported = ($p.reasons.Count -eq 0)

    $script:PlatformProfileCache = $p
    $script:PlatformProfileAt = Get-Date
    return $p
}

# 单项能力判定：只回答「这一项按规则能不能做」，不回答「现在读不读得到」。
# kind: os / cpu / gpu / temp
function Test-PlatformCapability([string]$Kind, $Profile = $null) {
    if (-not $Profile) { $Profile = Get-PlatformProfile }
    switch ($Kind) {
        'os' { return [bool]$Profile.osOk }
        'cpu' { return ($Profile.cpuVendor -in @('intel', 'amd')) }
        'gpu' { return ($Profile.gpuVendor -eq 'nvidia') }
        'temp' {
            if (-not $Profile.osOk) { return $false }
            # 温度还被品牌限制：只有联想有已实现的适配器
            return (([string]$Profile.systemVendor) -match '(?i)LENOVO|LEGION|THINKPAD')
        }
        default { return $false }
    }
}

function Get-PlatformReasonText([string]$Reason) {
    switch ($Reason) {
        'unsupportedOs' { return '仅支持 Windows 10 1809 及以上版本' }
        'unsupportedOsBuild' { return 'Windows 版本过低（需 10.0.17763 及以上）' }
        'unsupportedArch' { return '不支持 ARM 架构的 Windows' }
        'unsupportedCpu' { return '仅支持 Intel / AMD 处理器' }
        'unsupportedGpu' { return 'GPU 指标仅支持 NVIDIA 显卡' }
        'vendorNotSupported' { return '该品牌暂未提供固件温度通道' }
        'vendorNeedsAdmin' { return '读取厂商传感器需要管理员权限' }
        'vendorNoChannel' { return '该机型固件未暴露温度接口' }
        'vendorNotImplemented' { return '该机型未实现此传感器' }
        'vendorOutOfRange' { return '传感器返回值超出合理区间' }
        'vendorReadFailed' { return '厂商传感器读取失败' }
        'throttleLogUnavailable' { return 'Windows 系统日志不可读' }
        default { return '' }
    }
}
