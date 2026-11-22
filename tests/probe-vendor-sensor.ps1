# 厂商温度通道探针（v2.1.11）
# 验证：
#   - 适配器只按系统厂商匹配（联想），非联想不猜
#   - 能力 ID 白名单固定，且**绝不调用** SetFeatureValue
#   - 类不存在时返回 vendorNoChannel（不抛异常、不刷屏）
#   - 真实读取：返回 ok / value / reason / source 四要素；非管理员给出 vendorNeedsAdmin
# 非管理员运行不视为失败（能力探测）；只有「结构不对 / 抛异常 / 越界值」才算失败。
# 用法（管理员可拿到真值）：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-vendor-sensor.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$okText, [string]$badText) { if ($cond) { Ok $okText } else { Bad $badText } }
function Note([string]$m) { Write-Host "  · $m" -ForegroundColor DarkGray }

Write-Host "== 厂商温度通道探针 ==" -ForegroundColor Cyan
. (Join-Path $root 'src\app\platform-rules.ps1')
. (Join-Path $root 'src\app\vendor-sensor.ps1')

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Note ("管理员=" + $isAdmin)

# ---- 白名单 ----
Assert ($script:VendorTempWhitelist.CpuTemp -eq [uint32]0x05040000) 'CPU 温度 ID = 0x05040000' 'CPU 温度 ID 不对'
Assert ($script:VendorTempWhitelist.GpuTemp -eq [uint32]0x05050000) 'GPU 温度 ID = 0x05050000' 'GPU 温度 ID 不对'
Assert ($script:VendorTempMinC -eq 15 -and $script:VendorTempMaxC -eq 110) '合理区间 15–110 °C' '合理区间被改动'

# ---- 适配器匹配 ----
$lenovo = Get-VendorTempAdapter ([ordered]@{ systemVendor = 'LENOVO' })
$legion = Get-VendorTempAdapter ([ordered]@{ systemVendor = 'Legion' })
$asus = Get-VendorTempAdapter ([ordered]@{ systemVendor = 'ASUSTeK COMPUTER INC.' })
Assert ($null -ne $lenovo -and $lenovo.id -eq 'lenovo-wmi') 'LENOVO 匹配联想适配器' 'LENOVO 未匹配适配器'
Assert ($null -ne $legion) 'Legion 匹配联想适配器' 'Legion 未匹配适配器'
Assert ($null -eq $asus) 'ASUS 不匹配任何适配器（不猜）' 'ASUS 被错误匹配'

# ---- 类不存在：必须返回原因而不是抛异常 ----
$fake = @{ id = 'fake'; nc = 'root/WMI'; class = 'PERFCAPTURE_NOT_A_CLASS'; method = 'GetFeatureValue' }
$ch = Test-VendorTempChannel $fake
Assert ($ch.ok -eq $false -and $ch.reason -eq 'vendorNoChannel') '不存在的类 → vendorNoChannel' '不存在的类未返回 vendorNoChannel'
$ir = Invoke-VendorFeatureValue $fake ([uint32]0x05040000)
Assert ($ir.ok -eq $false -and $ir.reason -in @('vendorNoChannel', 'vendorReadFailed')) '调用不存在的类 → 明确失败原因' '调用不存在的类产生了意外结果'

# ---- 静态红线：没有写接口调用 ----
$venPs = Get-Content (Join-Path $root 'src\app\vendor-sensor.ps1') -Raw -Encoding UTF8
$badCall = [regex]::IsMatch($venPs, 'Invoke-CimMethod[^\r\n]*SetFeatureValue|MethodName\s+["'']SetFeatureValue')
Assert (-not $badCall) '没有调用 SetFeatureValue（只读）' '检测到 SetFeatureValue 调用（违反只读红线）'

# ---- 真实读取 ----
$snap = Get-VendorCpuTempSnapshot -Fresh
foreach ($k in 'ok', 'value', 'unit', 'source', 'vendor', 'reason', 'detail', 'at') {
    Assert ($snap.Contains($k)) ("快照含字段 " + $k) ("快照缺字段 " + $k)
}
if ($snap.ok) {
    Assert ($snap.value -ge 15 -and $snap.value -le 110) ("实测 CPU 温度 " + $snap.value + " °C（来源 " + $snap.source + "）") '实测温度超出合理区间'
} else {
    Note ("未读到温度：reason=" + $snap.reason + " detail=" + $snap.detail)
    Assert ($snap.reason -in @('vendorNotSupported', 'vendorNeedsAdmin', 'vendorNoChannel', 'vendorNotImplemented', 'vendorReadFailed', 'vendorOutOfRange')) '未读到时给出了明确原因码（不是 0）' '未读到时原因码缺失'
    if (-not $isAdmin -and $snap.reason -ne 'vendorNeedsAdmin' -and $snap.reason -ne 'vendorNotSupported') {
        Bad '非管理员时未提示需要管理员'
    }
}

# ---- 扩展中心用的可用性结论 ----
$av = Get-VendorTempAvailability
Assert ($av.state -in @('enabled', 'unsupported', 'failed')) ("可用性状态合法：" + $av.state) '可用性状态非法'
Note ("可用性：" + ($av | ConvertTo-Json -Compress))

Write-Host ""
if ($fail -eq 0) { Write-Host "== 厂商温度通道探针通过 ==" -ForegroundColor Green; exit 0 }
Write-Host ("== 失败 " + $fail + " 项 ==") -ForegroundColor Red
exit 1
