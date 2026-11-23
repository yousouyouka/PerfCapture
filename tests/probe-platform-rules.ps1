# 平台覆盖规则探针（v2.1.10）
# 验证：
#   - CPU 厂商识别（Intel / AMD / 其它）
#   - GPU 厂商识别（NVIDIA / AMD / Intel / 虚拟适配器）
#   - 覆盖判定：Windows 版本、CPU、GPU 三道闸门
#   - 能力判定：os / cpu / gpu / temp
# 全部为纯函数或只读探测，不依赖管理员；不通过时 exit 1。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-platform-rules.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$okText, [string]$badText) { if ($cond) { Ok $okText } else { Bad $badText } }

Write-Host "== 平台覆盖规则探针 ==" -ForegroundColor Cyan
. (Join-Path $root 'src\app\platform-rules.ps1')
Assert ((Get-Command Get-PlatformProfile -ErrorAction SilentlyContinue) -ne $null) '规则模块已加载' '规则模块未加载'

# ---- CPU 厂商 ----
Assert ((Get-CpuVendorName 'GenuineIntel' '') -eq 'intel') 'GenuineIntel → intel' 'GenuineIntel 识别错误'
Assert ((Get-CpuVendorName 'AuthenticAMD' '') -eq 'amd') 'AuthenticAMD → amd' 'AuthenticAMD 识别错误'
Assert ((Get-CpuVendorName 'CentaurHauls' 'Zhaoxin') -eq 'other') '未知厂商 → other（不猜）' '未知厂商被错误归类'
Assert ((Get-CpuVendorName '' '13th Gen Intel(R) Core(TM) i9-13900H') -eq 'intel') '缺 Manufacturer 时按型号兜底（Intel）' 'Intel 型号兜底失败'
Assert ((Get-CpuVendorName '' 'AMD Ryzen 9 8945HX') -eq 'amd') '缺 Manufacturer 时按型号兜底（AMD）' 'AMD 型号兜底失败'

# ---- GPU 厂商 ----
Assert ((Get-GpuVendorName 'NVIDIA GeForce RTX 5060 Laptop GPU') -eq 'nvidia') 'NVIDIA 识别' 'NVIDIA 识别失败'
Assert ((Get-GpuVendorName 'AMD Radeon(TM) 610M') -eq 'amd') 'AMD 显卡识别' 'AMD 显卡识别失败'
Assert ((Get-GpuVendorName 'Intel(R) UHD Graphics') -eq 'intel') 'Intel 显卡识别' 'Intel 显卡识别失败'
Assert ((Get-GpuVendorName 'MuMu Virtual Display Adapter') -eq 'virtual') '虚拟适配器不算显卡' '虚拟适配器被当成显卡'

# ---- 真实平台画像 ----
$p = Get-PlatformProfile -Fresh
Assert ($p.osBuild -ge 17763) ("Windows 版本在支持范围内（build " + $p.osBuild + "）") 'Windows 版本低于 10 1809'
Assert ($p.cpuVendor -in @('intel', 'amd')) ("CPU 厂商在支持范围内：" + $p.cpuVendor) ('不支持的 CPU 厂商：' + $p.cpuVendor)
Assert ($p.gpuVendor -eq 'nvidia') ("GPU 厂商在支持范围内：" + $p.gpuModel) ('不支持的 GPU 厂商：' + $p.gpuVendor)

# ---- 闸门：单点判定（用合成画像，不依赖本机） ----
$fake = [ordered]@{ osOk = $true; cpuVendor = 'amd'; gpuVendor = 'amd'; systemVendor = 'ASUS' }
Assert ((Test-PlatformCapability 'gpu' $fake) -eq $false) 'AMD 显卡 → GPU 能力为假（规则：只做 NVIDIA）' 'AMD 显卡被判定为可用'
$fake2 = [ordered]@{ osOk = $false; cpuVendor = 'intel'; gpuVendor = 'nvidia'; systemVendor = 'LENOVO' }
Assert ((Test-PlatformCapability 'os' $fake2) -eq $false) '旧系统 → OS 能力为假' '旧系统被判定为可用'
Assert ((Test-PlatformCapability 'temp' $fake2) -eq $false) '系统不支持时温度能力也为假' '系统不支持时温度仍被判可用'
$fake3 = [ordered]@{ osOk = $true; cpuVendor = 'intel'; gpuVendor = 'nvidia'; systemVendor = 'ASUS' }
Assert ((Test-PlatformCapability 'temp' $fake3) -eq $false) '非联想 → 温度能力为假（不假装通用）' '非联想被判定有温度通道'

# ---- 原因文案 ----
foreach ($rc in 'unsupportedCpu', 'unsupportedGpu', 'vendorNotSupported', 'throttleLogUnavailable') {
    $txt = Get-PlatformReasonText $rc
    Assert ([bool]$txt) ("原因码有可读文案：" + $rc) ("原因码缺文案：" + $rc)
}

Write-Host ""
if ($fail -eq 0) { Write-Host "== 平台覆盖规则探针通过 ==" -ForegroundColor Green; exit 0 }
Write-Host ("== 失败 " + $fail + " 项 ==") -ForegroundColor Red
exit 1
