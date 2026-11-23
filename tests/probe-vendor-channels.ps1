# 多品牌固件通道探测（只读，v2.1.10）
# 目的：换一台机器时，先回答「这台机器有没有可走的固件通道」，再谈适配。
#   - 只做元数据查询（Get-CimClass），**不调用任何非联想方法**，不会写任何寄存器
#   - 输出目录里每个类在本机是否存在、有哪些方法、证据等级、是否已实现
#   - 只对联想走白名单只读读取（GetFeatureValue 0x05040000）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-vendor-channels.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  [!!] $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$okText, [string]$badText) { if ($cond) { Ok $okText } else { Bad $badText } }
function Note([string]$m) { Write-Host "  ·  $m" -ForegroundColor DarkGray }

Write-Host "== 多品牌固件通道探测（只读）==" -ForegroundColor Cyan
. (Join-Path $root 'src\app\platform-rules.ps1')
. (Join-Path $root 'src\app\vendor-sensor.ps1')

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$p = Get-PlatformProfile -Fresh
Write-Host ("  机型: " + $p.systemVendor + " " + $p.systemModel + " | BIOS " + $p.bios)
Write-Host ("  CPU : " + $p.cpuVendor + " " + $p.cpuModel)
Write-Host ("  GPU : " + $p.gpuVendor + " " + $p.gpuModel)
Write-Host ("  OS  : build " + $p.osBuild + " " + $p.osArch + " | 管理员=" + $isAdmin)
Write-Host ""

# ---- 1. 通道目录：结构自检 ----
$map = @(Get-VendorChannelMap)
Assert ($map.Count -ge 8) ("通道目录 " + $map.Count + " 项") '通道目录条目过少'
$lenovoRows = @($map | Where-Object { $_.vendor -eq 'lenovo' -and $_.class -eq 'LENOVO_OTHER_METHOD' })
Assert ($lenovoRows.Count -eq 1 -and $lenovoRows[0].implemented) '联想 LENOVO_OTHER_METHOD 标记为已实现' '联想通道未标记为已实现'
$acpi = $map | Where-Object { $_.class -eq 'MSAcpi_ThermalZoneTemperature' }
Assert ($acpi.evidence -eq 'banned') 'ACPI 热区标记为禁用（不冒充核心温度）' 'ACPI 热区未标记为禁用'
# 除联想外，任何条目都不得标记为已实现
$others = @($map | Where-Object { $_.vendor -ne 'lenovo' -and $_.implemented })
Assert ($others.Count -eq 0) '非联想通道均未实现（未验证不接入）' ("有非联想通道被标记为已实现：" + (($others | ForEach-Object { $_.class }) -join ','))

# ---- 2. 本机通道清单 ----
Write-Host ""
Write-Host "  本机类探测结果：" -ForegroundColor White
foreach ($r in $map) {
    $flag = if ($r.present) { 'present' } else { 'absent ' }
    $mark = if ($r.present) { '<<' } else { '  ' }
    Write-Host ("   " + $flag + " " + $mark + " " + $r.vendor.PadRight(8) + " " + $r.class.PadRight(32) + " " + $r.evidence)
    if ($r.present -and $r.detail) { Note ("   " + $r.detail) }
}

$present = @($map | Where-Object { $_.present })
Write-Host ""
Note ("本机存在的通道：" + (($present | ForEach-Object { $_.vendor + '/' + $_.class }) -join ' , '))

# ---- 3. 判定：能不能读温度 ----
Write-Host ""
$snap = $null
$adapter = Get-VendorTempAdapter $p
if ($adapter) {
    $ch = Test-VendorTempChannel $adapter
    Assert ($ch.ok) ('已实现适配器通道探测通过：' + $adapter.label) ('适配器通道探测失败：' + $ch.detail)
    $snap = Get-VendorCpuTempSnapshot -Fresh
    if ($snap.ok) {
        Ok ("实测 CPU 温度 " + $snap.value + " °C（来源 " + $snap.source + "）")
    } else {
        Note ("未读到温度：reason=" + $snap.reason + " detail=" + $snap.detail)
        Assert ($snap.reason -in @('vendorNotSupported', 'vendorNeedsAdmin', 'vendorNoChannel', 'vendorNotImplemented', 'vendorReadFailed', 'vendorOutOfRange')) '未读到时给出明确原因码（不是 0）' '未读到时原因码缺失'
    }
} else {
    Note ("厂商 " + $p.systemVendor + " 没有已实现的适配器 → CPU 温度 N/A（reason=vendorNotSupported）")
    $cand = @($present | Where-Object { $_.vendor -ne 'generic' -and $_.role -match 'temp' })
    if ($cand.Count -gt 0) {
        Write-Host "  发现可评估的候选通道（未接入）：" -ForegroundColor Yellow
        foreach ($c in $cand) { Note ($c.vendor + '/' + $c.class + " — " + $c.note) }
        Note '要接入必须：新增适配器 + 真机探针 + 读数与 BIOS/厂商工具对比 ≤3 ℃，再改覆盖表'
    } else {
        Note '本机没有已知的固件温度通道 → 温度维持 N/A，不做估算'
    }
}

# ---- 4. 交叉校验：同一厂商的第二条只读通道（仅 GAMEZONE.GetCPUTemp，绝不调 Set*/Status*）----
Write-Host ""
$gz = $map | Where-Object { $_.vendor -eq 'lenovo' -and $_.class -eq 'LENOVO_GAMEZONE_DATA' -and $_.present }
if (-not $gz) {
    Note '本机没有 LENOVO_GAMEZONE_DATA，跳过交叉校验'
} elseif (-not $isAdmin) {
    Note '需要管理员才能做交叉校验（GAMEZONE 的 ACL 同样只给管理员），跳过'
} else {
    try {
        $gzInst = Get-CimInstance -Namespace 'root/WMI' -ClassName 'LENOVO_GAMEZONE_DATA' -ErrorAction Stop | Select-Object -First 1
        $r2 = Invoke-CimMethod -InputObject $gzInst -MethodName 'GetCPUTemp' -ErrorAction Stop
        $v2 = $null
        foreach ($n in 'value', 'Value', 'ReturnValue') {
            $pp = $r2.PSObject.Properties[$n]
            if ($pp -and $null -ne $pp.Value) { $v2 = $pp.Value; break }
        }
        if ($null -eq $v2) {
            Note ('GAMEZONE.GetCPUTemp 返回了但没有数值：' + ($r2 | ConvertTo-Json -Compress))
        } else {
            Ok ('GAMEZONE.GetCPUTemp = ' + $v2 + ' °C（第二条只读通道）')
            if ($snap -and $snap.ok -and $snap.value) {
                $d = [math]::Abs([int]$v2 - [int]$snap.value)
                if ($d -le 3) { Ok ('与主通道偏差 ' + $d + ' °C（≤3 °C，可作后备通道）') }
                else { Note ('与主通道偏差 ' + $d + ' °C（>3 °C，不作后备，需查是否不同传感器）') }
            }
        }
    } catch {
        Note ('GAMEZONE.GetCPUTemp 调用失败：' + $_.Exception.Message)
    }
}

Write-Host ""
if ($fail -eq 0) { Write-Host "== 通道探测通过（exit 0，能力结论不作为回归失败）==" -ForegroundColor Green; exit 0 }
Write-Host ("== 失败 " + $fail + " 项 ==") -ForegroundColor Red
exit 1
