# 厂商 ACPI-WMI 传感器通道探针（联想 / 只读）
# 目的：验证能否在不装驱动、不依赖第三方软件的前提下读到 CPU/GPU 温度与风扇转速。
# 依据：Lenovo Legion Toolkit 的 SensorsController 调 root\WMI:LENOVO_OTHER_METHOD.GetFeatureValue，
#       CapabilityID: CpuCurrentTemperature=0x05040000 / GpuCurrentTemperature=0x05050000 /
#                     CpuCurrentFanSpeed=0x04030001 / GpuCurrentFanSpeed=0x04030002。
#
# 安全边界（硬约束）：
#   - 只调 GetFeatureValue（读），**绝不调 SetFeatureValue**——同族方法能改温度墙/功耗墙。
#   - 不写注册表、不装组件、不改发布资产。
#   - 该探针是「能力探测」：机型不支持 / 无管理员权限都算有效结果，不作为回归失败（恒 exit 0）。
#
# 用法（必须管理员，WMI 类 ACL 只给管理员）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-vendor-wmi.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red }
function Warn([string]$m) { Write-Host "  ⚠ $m" -ForegroundColor Yellow }

$CAP = [ordered]@{
    'CPU 温度'    = [uint32]0x05040000
    'GPU 温度'    = [uint32]0x05050000
    'CPU 风扇转速' = [uint32]0x04030001
    'GPU 风扇转速' = [uint32]0x04030002
}

Write-Host '== 厂商 WMI 传感器通道探针（联想，只读）==' -ForegroundColor Cyan

# ---- 1. 机器身份：结论只在特定机型上成立，必须留档 ----
$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
Write-Host ("  机型: {0} {1}" -f $cs.Manufacturer, $cs.Model)
Write-Host ("  BIOS: {0} ({1})" -f $bios.SMBIOSBIOSVersion, $bios.ReleaseDate)
if ($cs.Manufacturer -notmatch 'LENOVO') {
    Warn '非联想机型：本探针的 ID 表不适用，结论仅作「不支持」记录'
}

# ---- 2. 类与方法是否暴露（类元数据通常不需要实例级权限） ----
$cls = $null
try {
    $cls = Get-CimClass -Namespace root\WMI -ClassName LENOVO_OTHER_METHOD -ErrorAction Stop
    $methods = @($cls.CimClassMethods | ForEach-Object Name)
    Ok ("LENOVO_OTHER_METHOD 存在，方法: " + ($methods -join ', '))
    if ($methods -notcontains 'GetFeatureValue') { Bad '类里没有 GetFeatureValue，无法读取' }
    if ($methods -contains 'SetFeatureValue') { Warn '类里存在 SetFeatureValue（可写）：本探针绝不调用' }
} catch {
    Warn ('类不可读: ' + $_.Exception.Message)
}

# ---- 3. 需要管理员：ACL 只给管理员，普通权限连实例都枚举不到 ----
$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
if (-not $isAdmin) {
    Warn '当前不是管理员：该 WMI 类的实例查询会被拒（本机实测「拒绝访问」）'
    Write-Host ''
    Write-Host '  请用管理员 PowerShell 重跑本探针：' -ForegroundColor Yellow
    Write-Host '    powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-vendor-wmi.ps1' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '== 跳过（非失败）==' -ForegroundColor Cyan
    exit 0
}

# ---- 4. 取实例并逐个 ID 读取 ----
$inst = $null
try {
    $inst = Get-CimInstance -Namespace root\WMI -ClassName LENOVO_OTHER_METHOD -ErrorAction Stop | Select-Object -First 1
    if (-not $inst) { throw '实例为空' }
    Ok '已取得 LENOVO_OTHER_METHOD 实例'
} catch {
    Bad ('实例查询失败: ' + $_.Exception.Message)
    Write-Host '== 结束（未取到实例，机型可能不提供该接口）==' -ForegroundColor Cyan
    exit 0
}

# 参数类型在不同 BIOS 上可能是 uint32 或 int32：先按 uint32，失败再退回 int32，
# 并把「哪种写法成功」记下来，供后续读取器实现参考。
function Read-FeatureValue([uint32]$Id) {
    foreach ($arg in @([uint32]$Id, [int32]$Id)) {
        try {
            $r = Invoke-CimMethod -InputObject $inst -MethodName GetFeatureValue -Arguments @{ IDs = $arg } -ErrorAction Stop
            if ($null -eq $r) { continue }
            $v = $null
            if ($r.PSObject.Properties.Name -contains 'Value') { $v = $r.Value }
            return [pscustomobject]@{ ok = $true; value = $v; argType = $arg.GetType().Name; raw = $r }
        } catch { $last = $_.Exception.Message }
    }
    return [pscustomobject]@{ ok = $false; value = $null; argType = ''; raw = $null; error = $last }
}

$results = [ordered]@{}
foreach ($name in $CAP.Keys) {
    $id = $CAP[$name]
    $r = Read-FeatureValue $id
    $hex = '0x{0:X8}' -f $id
    if (-not $r.ok) {
        Warn ("{0} ({1}) 调用失败: {2}" -f $name, $hex, $r.error)
        $results[$name] = $null
        continue
    }
    $v = $r.value
    if ($null -eq $v) { Warn ("{0} ({1}) 返回无 Value 字段（原始: {2}）" -f $name, $hex, ($r.raw | Out-String).Trim()); $results[$name] = $null; continue }

    # 语义校验：温度合理区间 15–110 °C；0 / 负数 = 该机型未实现，不是「0 度」
    if ($name -like '*温度*') {
        if ($v -ge 15 -and $v -le 110) {
            Ok ("{0} ({1}) = {2} °C   [入参类型 {3}]" -f $name, $hex, $v, $r.argType)
            $results[$name] = [double]$v
        } elseif ($v -le 0) {
            Warn ("{0} ({1}) = {2}：该机型未实现此 ID（按 N/A 处理，不当作 0 度）" -f $name, $hex, $v)
            $results[$name] = $null
        } else {
            Warn ("{0} ({1}) = {2}：超出合理温度区间，语义可疑，需人工核对" -f $name, $hex, $v)
            $results[$name] = $null
        }
    } else {
        if ($v -gt 0 -and $v -le 8000) { Ok ("{0} ({1}) = {2} rpm" -f $name, $hex, $v); $results[$name] = [double]$v }
        else { Warn ("{0} ({1}) = {2}：转速区间可疑或未实现" -f $name, $hex, $v); $results[$name] = $null }
    }
}

# ---- 5. 二次采样：温度应稳定或小幅变化（能排除「返回常量/假值」） ----
if ($results['CPU 温度']) {
    Start-Sleep -Seconds 2
    $r2 = Read-FeatureValue ([uint32]0x05040000)
    if ($r2.ok -and $null -ne $r2.value) {
        $d = [double]$r2.value - [double]$results['CPU 温度']
        if ([Math]::Abs($d) -le 15) { Ok ("二次采样 {0} °C（Δ{1:+0;-0;0}），读数在动，不像常量" -f $r2.value, $d) }
        else { Warn ("二次采样 {0} °C（Δ{1}），波动偏大，需确认是否空载波动" -f $r2.value, $d) }
    }
} else {
    Warn '没有可用 CPU 温度读数，跳过二次采样'
}

# ---- 6. 结论 ----
Write-Host ''
$cpuT = $results['CPU 温度']
if ($cpuT) {
    Ok ("结论：本机可零驱动读 CPU 温度（{0} °C），可进入扩展接入" -f $cpuT)
} else {
    Warn '结论：本机未取得可用 CPU 温度；该通道不可用或需换 ID，扩展保持不接入'
}
Write-Host '== 探针结束（exit 0，能力探测不作为回归失败）==' -ForegroundColor Cyan
exit 0
