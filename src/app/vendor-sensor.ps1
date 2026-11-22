# 厂商固件温度通道（CPU 温度）
#
# 规则见《数据源与平台覆盖规则.md》§3。要点：
#   - 只读：只调 GetFeatureValue，白名单 ID；绝不调 SetFeatureValue（它能改温度墙/功耗墙）。
#   - 不装驱动、不注入：特权寄存器由 BIOS/EC 读，我们只发一个 WMI 方法调用。
#   - 只做联想（LENOVO_OTHER_METHOD / 0x05040000）。其它品牌必须新增适配器 + 真机探针，
#     不能复用联想的 ID 表（见规则文档 §3.4）。
#   - 采不到 → 返回 ok=$false + reason，字段回 null；绝不用 0 或估算值顶替。
#
# 本文件依赖 platform-rules.ps1 的 Get-PlatformProfile；两者一起 dot-source。

# 能力 ID 白名单（只读）。新增 ID 前先改规则文档 §3.2。
$script:VendorTempWhitelist = @{
    CpuTemp = [uint32]0x05040000
    GpuTemp = [uint32]0x05050000
}
$script:VendorTempMinC = 15
$script:VendorTempMaxC = 110

# 适配器表：新增品牌 = 在表里加一项（探测 + 读取两个脚本块），不改采样/报告。
# 只有联想是「已实现」；其余条目故意不写，避免用未验证的类名去碰运气。
$script:VendorTempAdapters = @{
    lenovo = @{
        id = 'lenovo-wmi'
        label = '联想固件通道（LENOVO_OTHER_METHOD）'
        match = '(?i)LENOVO|LEGION|THINKPAD|IDEAPAD'
        nc = 'root/WMI'
        class = 'LENOVO_OTHER_METHOD'
        method = 'GetFeatureValue'
    }
}

# 读取结果缓存：EC 轮询 2 s 一次足够，避免采样循环每秒都发 WMI 调用。
$script:VendorTempCache = $null
$script:VendorTempCacheAt = [datetime]::MinValue
$script:VendorTempCacheTtlMs = 1500
$script:VendorTempFailCount = 0
$script:VendorTempCooldownUntil = [datetime]::MinValue

function Get-VendorTempAdapter($Profile = $null) {
    if (-not $Profile) { $Profile = Get-PlatformProfile }
    $sv = [string]$Profile.systemVendor
    foreach ($k in $script:VendorTempAdapters.Keys) {
        $a = $script:VendorTempAdapters[$k]
        if ($sv -and $sv -match $a.match) { return $a }
    }
    return $null
}

# 通道探测：类/方法是否存在（不需要管理员也能看元数据）；实例是否可读另行判断。
function Test-VendorTempChannel($Adapter) {
    if (-not $Adapter) { return @{ ok = $false; reason = 'vendorNotSupported'; detail = '' } }
    try {
        $cls = Get-CimClass -Namespace $Adapter.nc -ClassName $Adapter.class -ErrorAction Stop
        $names = @($cls.CimClassMethods | ForEach-Object { [string]$_.Name })
        if ($names -notcontains $Adapter.method) {
            return @{ ok = $false; reason = 'vendorNoChannel'; detail = ('类存在但缺少方法 ' + $Adapter.method) }
        }
        return @{ ok = $true; reason = ''; detail = '' }
    } catch {
        return @{ ok = $false; reason = 'vendorNoChannel'; detail = $_.Exception.Message }
    }
}

# 只读调用：返回 @{ ok; value; reason; detail }
# 失败原因细分：needsAdmin（ACL 拒绝）/ noInstance / invokeFailed / notImplemented / outOfRange
function Invoke-VendorFeatureValue($Adapter, [uint32]$Id) {
    $out = @{ ok = $false; value = $null; reason = 'vendorReadFailed'; detail = '' }
    if (-not $Adapter) { $out.reason = 'vendorNotSupported'; return $out }
    try {
        $inst = Get-CimInstance -Namespace $Adapter.nc -ClassName $Adapter.class -ErrorAction Stop | Select-Object -First 1
    } catch {
        $msg = [string]$_.Exception.Message
        if ($msg -match '(?i)access|denied|拒绝访问|权限') { $out.reason = 'vendorNeedsAdmin' }
        elseif ($msg -match '(?i)not found|无效的类|Invalid class') { $out.reason = 'vendorNoChannel' }
        else { $out.reason = 'vendorReadFailed' }
        $out.detail = $msg
        return $out
    }
    if (-not $inst) { $out.reason = 'vendorNoChannel'; $out.detail = 'no instance'; return $out }
    try {
        $r = Invoke-CimMethod -InputObject $inst -MethodName $Adapter.method -Arguments @{ IDs = $Id } -ErrorAction Stop
    } catch {
        $msg = [string]$_.Exception.Message
        if ($msg -match '(?i)access|denied|拒绝访问|权限') { $out.reason = 'vendorNeedsAdmin' }
        else { $out.reason = 'vendorReadFailed' }
        $out.detail = $msg
        return $out
    }
    if ($null -eq $r) { $out.reason = 'vendorReadFailed'; $out.detail = 'null result'; return $out }
    # 返回 Boolean = 调用是否成功；数值在 value 属性（大小写不敏感）
    $okProp = $r.PSObject.Properties['ReturnValue']
    if ($okProp -and $okProp.Value -is [bool] -and -not $okProp.Value) {
        $out.reason = 'vendorNotImplemented'; $out.detail = 'ReturnValue=false'; return $out
    }
    $vp = $r.PSObject.Properties['value']
    if (-not $vp -or $null -eq $vp.Value) { $out.reason = 'vendorReadFailed'; $out.detail = 'no value'; return $out }
    $num = 0
    if (-not [int]::TryParse([string]$vp.Value, [ref]$num)) { $out.reason = 'vendorReadFailed'; $out.detail = 'not int'; return $out }
    # 0 / 负数 = 该机型未实现，不是 0 °C
    if ($num -le 0) { $out.reason = 'vendorNotImplemented'; $out.detail = [string]$num; return $out }
    if ($num -lt $script:VendorTempMinC -or $num -gt $script:VendorTempMaxC) {
        $out.reason = 'vendorOutOfRange'; $out.detail = [string]$num; return $out
    }
    $out.ok = $true; $out.value = $num; $out.reason = ''
    return $out
}

# 对外唯一入口：CPU 温度快照（带缓存与失败冷却）
# 返回 ordered hashtable：ok / value / unit / source / vendor / reason / detail / at
function Get-VendorCpuTempSnapshot([switch]$Fresh) {
    $now = Get-Date
    if (-not $Fresh -and $script:VendorTempCache -and ($now - $script:VendorTempCacheAt).TotalMilliseconds -lt $script:VendorTempCacheTtlMs) {
        return $script:VendorTempCache
    }
    $snap = [ordered]@{
        ok = $false; value = $null; unit = 'C'; source = ''
        vendor = ''; reason = ''; detail = ''; at = $now.ToString('yyyy-MM-dd HH:mm:ss')
    }
    $profile = Get-PlatformProfile
    $adapter = Get-VendorTempAdapter $profile
    if (-not $adapter) {
        $snap.reason = 'vendorNotSupported'
        $script:VendorTempCache = $snap; $script:VendorTempCacheAt = $now
        return $snap
    }
    $snap.vendor = $adapter.id
    $snap.source = 'vendor-wmi:' + $adapter.id
    if ($now -lt $script:VendorTempCooldownUntil) {
        $snap.reason = 'vendorReadFailed'; $snap.detail = 'cooling down'
        $script:VendorTempCache = $snap; $script:VendorTempCacheAt = $now
        return $snap
    }
    $r = Invoke-VendorFeatureValue $adapter $script:VendorTempWhitelist.CpuTemp
    if ($r.ok) {
        $snap.ok = $true; $snap.value = [int]$r.value
        $script:VendorTempFailCount = 0
    } else {
        $snap.reason = $r.reason
        $snap.detail = [string]$r.detail
        $script:VendorTempFailCount++
        # 连续 3 次失败 → 冷却 60 s，避免采样循环每秒重试（EC/WMI 争用会拖慢整机）
        if ($script:VendorTempFailCount -ge 3) {
            $script:VendorTempCooldownUntil = $now.AddSeconds(60)
            $script:VendorTempFailCount = 0
        }
    }
    $script:VendorTempCache = $snap
    $script:VendorTempCacheAt = $now
    return $snap
}

# 供扩展中心显示：内置能力的可用状态（不需要安装，只报能力）
function Get-VendorTempAvailability {
    $profile = Get-PlatformProfile
    if (-not $profile.osOk) { return @{ state = 'unsupported'; reason = ($profile.reasons | Select-Object -First 1) } }
    $adapter = Get-VendorTempAdapter $profile
    if (-not $adapter) { return @{ state = 'unsupported'; reason = 'vendorNotSupported' } }
    $ch = Test-VendorTempChannel $adapter
    if (-not $ch.ok) { return @{ state = 'unsupported'; reason = $ch.reason } }
    $snap = Get-VendorCpuTempSnapshot
    if ($snap.ok) { return @{ state = 'enabled'; reason = '' } }
    $st = if ($snap.reason -eq 'vendorNotImplemented' -or $snap.reason -eq 'vendorNoChannel') { 'unsupported' } else { 'failed' }
    return @{ state = $st; reason = $snap.reason }
}
