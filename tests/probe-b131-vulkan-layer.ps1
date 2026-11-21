# B131 扩展系统级注册痕迹清理探针（2.1.5）
# 真机故障背景：关闭 RTSS 扩展（非卸载）后，终末地内 DLSS 选项仍然消失，且重启游戏不恢复。
# 根因：RTSS 7.3.x 会把自己注册成 Vulkan 隐式层
#         HKLM\SOFTWARE\Khronos\Vulkan\ImplicitLayers            -> ...\vendor\Vulkan\RTSSVkLayer64.json
#         HKLM\SOFTWARE\WOW6432Node\Khronos\Vulkan\ImplicitLayers -> ...\vendor\Vulkan\RTSSVkLayer32.json
#       该注册是系统级、持久的：进程退出不会撤销，游戏每次创建 Vulkan 实例都会加载它，
#       被 overlay hook 干扰后直接隐藏 DLSS 选项（鹰角官方客服的答复即指向 RTSSVkLayer64.dll）。
#       旧实现只结束进程、不清注册，所以表现为「关不掉」。
# 本探针验证：
#   ① 能按「值名落在自有安装目录内」精确识别层注册；
#   ② 目录外路径、空路径一律不认（安全边界）；
#   ③ 清理只删自有的，Steam/OBS 等第三方层注册绝不被误删；
#   ④ 清理幂等、空 Root 安全空转；
#   ⑤ RTSS 安装键只在 InstallDir 指向自有目录时才认。
# 用 HKCU 临时层项做集成验证：不需要管理员权限，也不碰真实的 HKLM 现场。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b131-vulkan-layer.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  OK  $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  !!  $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }
function Skip([string]$m) { Write-Host "  --  $m" -ForegroundColor DarkGray }

Write-Host '== B131 Vulkan 层注册清理探针 ==' -ForegroundColor Cyan

# ---- stub 宿主依赖 ----
$script:Root = $root
$script:DataDir = Join-Path $env:TEMP ('PerfCapture-B131-data-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:UiMessages = New-Object System.Collections.ArrayList
function Write-AppLog([string]$text, [string]$lvl = 'INFO') { }
function Send-ToUi([hashtable]$payload) { [void]$script:UiMessages.Add($payload) }
function Save-Config { }
$script:Cfg = @{ extensions = @{} }

. (Join-Path $root 'src\app\80-Extensions.ps1')

$hkcuKey = 'HKCU:\Software\Khronos\Vulkan\ImplicitLayers'
$hklmKey = 'HKLM:\SOFTWARE\Khronos\Vulkan\ImplicitLayers'
$hklm32Key = 'HKLM:\SOFTWARE\WOW6432Node\Khronos\Vulkan\ImplicitLayers'

$tmp = Join-Path $env:TEMP ('PerfCapture-B131-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$vendor = Join-Path $tmp 'vendor'
$vkDir = Join-Path $vendor 'Vulkan'
$createdKey = $false
$regNames = @()

try {
    New-Item -ItemType Directory -Path $vkDir -Force | Out-Null
    # 造两份与 RTSS 同构的 layer 声明（内容不参与判定，只看值名路径）
    foreach ($n in 'RTSSVkLayer64.json', 'RTSSVkLayer32.json') {
        Set-Content -LiteralPath (Join-Path $vkDir $n) -Value '{"file_format_version":"1.0.0"}' -Encoding UTF8
    }

    if (-not (Test-Path -LiteralPath $hkcuKey)) {
        New-Item -Path $hkcuKey -Force | Out-Null
        $createdKey = $true
    }

    # ---- 1. 造两个「自有的」临时层项 ----
    foreach ($n in 'RTSSVkLayer64.json', 'RTSSVkLayer32.json') {
        $full = Join-Path $vkDir $n
        New-ItemProperty -Path $hkcuKey -Name $full -Value 0 -PropertyType DWord -Force | Out-Null
        $regNames += $full
    }

    # ---- 2. 识别：只认落在 vendor 内的 ----
    $found = @(Get-ExtensionVulkanLayerRegistrations $vendor)
    Assert ($found.Count -eq 2) "识别到 2 条自有 Vulkan 层注册（实际 $($found.Count)）" "应识别 2 条，实际 $($found.Count)"
    Assert (@($found | Where-Object { $_.Name -like "$vkDir\*" }).Count -eq 2) '识别项全部指向自有 Vulkan 目录' '存在指向目录外的识别结果'
    Assert (@($found | Where-Object { $_.Hive -eq 'HKCU' }).Count -ge 2) '覆盖 HKCU 位置' '未覆盖 HKCU 位置'

    # ---- 3. 安全边界：目录外 / 空路径不认 ----
    $outsideRoot = Join-Path $tmp 'other-vendor'
    New-Item -ItemType Directory -Path $outsideRoot -Force | Out-Null
    Assert (@(Get-ExtensionVulkanLayerRegistrations $outsideRoot).Count -eq 0) '目录外 Root 不识别任何层' '目录外 Root 误识别了层'
    Assert (@(Get-ExtensionVulkanLayerRegistrations '').Count -eq 0) '空 Root 安全返回空' '空 Root 返回了结果'

    # ---- 4. 不误伤第三方层（Steam / OBS）----
    $steamBefore = 0
    foreach ($k in $hklmKey, $hklm32Key) {
        if (Test-Path -LiteralPath $k) {
            $steamBefore += @((Get-ItemProperty -LiteralPath $k).PSObject.Properties | Where-Object { $_.Name -match 'Steam' }).Count
        }
    }
    $obsBefore = 0
    if (Test-Path -LiteralPath $hkcuKey) {
        $obsBefore = @((Get-ItemProperty -LiteralPath $hkcuKey).PSObject.Properties | Where-Object { $_.Name -match 'obs-studio' }).Count
    }

    # ---- 5. 清理：撤掉自有的两条 ----
    $res = Clear-ExtensionSystemTraces 'probe' $vendor
    Assert ($res.ok -eq $true) '清理报告 ok' "清理报告失败：$(@($res.failed) -join '; ')"
    Assert ($res.removed -ge 2) "实际撤销 $($res.removed) 项" "撤销数量不足：$($res.removed)"
    Assert (@(Get-ExtensionVulkanLayerRegistrations $vendor).Count -eq 0) '清理后不再识别到自有层' '清理后仍识别到自有层'

    $regLeft = @($regNames | Where-Object { (Get-ItemProperty -LiteralPath $hkcuKey -ErrorAction SilentlyContinue).PSObject.Properties.Name -contains $_ })
    Assert ($regLeft.Count -eq 0) '注册表值确实被删除' "仍有 $($regLeft.Count) 个值残留"

    # ---- 6. 第三方层未被误删 ----
    $steamAfter = 0
    foreach ($k in $hklmKey, $hklm32Key) {
        if (Test-Path -LiteralPath $k) {
            $steamAfter += @((Get-ItemProperty -LiteralPath $k).PSObject.Properties | Where-Object { $_.Name -match 'Steam' }).Count
        }
    }
    $obsAfter = 0
    if (Test-Path -LiteralPath $hkcuKey) {
        $obsAfter = @((Get-ItemProperty -LiteralPath $hkcuKey).PSObject.Properties | Where-Object { $_.Name -match 'obs-studio' }).Count
    }
    Assert ($steamAfter -eq $steamBefore) "Steam 的层注册未被误删（$steamBefore → $steamAfter）" "Steam 层注册被误删（$steamBefore → $steamAfter）"
    Assert ($obsAfter -eq $obsBefore) "OBS 的层注册未被误删（$obsBefore → $obsAfter）" "OBS 层注册被误删（$obsBefore → $obsAfter）"

    # ---- 7. 幂等与空转 ----
    $res2 = Clear-ExtensionSystemTraces 'probe' $vendor
    Assert ($res2.ok -eq $true -and $res2.removed -eq 0) '重复清理幂等（ok 且 0 项）' '重复清理不幂等'
    $res3 = Clear-ExtensionSystemTraces 'probe' ''
    Assert ($res3.ok -eq $true -and $res3.removed -eq 0) '空 Root 清理安全空转' '空 Root 清理报错'

    # ---- 8. 安装键：只在 InstallDir 指向自有目录时才认 ----
    $keysOwn = @(Get-ExtensionInstallKeyRegistrations $vendor)
    $keysOther = @(Get-ExtensionInstallKeyRegistrations $outsideRoot)
    Assert ($keysOther.Count -eq 0) '目录外的安装键不认（用户自装 RTSS 不会被误删）' '目录外的安装键被误认'
    if (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Unwinder\RTSS') {
        $installDir = [string](Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Unwinder\RTSS' -ErrorAction SilentlyContinue).InstallDir
        if ($installDir) {
            Skip "现场存在 Unwinder 键，InstallDir=$installDir"
            $isOurs = $installDir.TrimEnd('\').StartsWith($vendor.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
            Assert (($keysOwn.Count -ge 1) -eq $isOurs) '安装键识别与 InstallDir 归属一致' '安装键识别与 InstallDir 归属不一致'
        }
    } else {
        Skip '现场无 Unwinder 键，跳过归属一致性断言'
    }

    # ---- 9. 注册表声明与实现一致（防止配置文件与代码脱节）----
    $realVendor = Join-Path $env:LOCALAPPDATA 'PerfCapture\extensions\rtss-shm\vendor'
    $json64 = Join-Path $realVendor 'Vulkan\RTSSVkLayer64.json'
    if (Test-Path -LiteralPath $json64) {
        $txt = Get-Content -LiteralPath $json64 -Raw
        Assert ($txt -match 'VK_LAYER_RTSS') '现场 layer 声明含 VK_LAYER_RTSS' 'layer 声明缺少 VK_LAYER_RTSS'
        Assert ($txt -match 'disable_environment') 'layer 声明提供 DISABLE_RTSS_LAYER 逃生口' 'layer 声明缺少 disable_environment'
        $regs = @(Get-ExtensionVulkanLayerRegistrations $realVendor)
        Skip "现场自有层注册当前 $($regs.Count) 条（0 表示已清理干净）"
    } else {
        Skip '现场未安装 RTSS 副本，跳过真实安装一致性断言'
    }
} finally {
    # 清理探针自己造的东西：先删值，再删可能由探针创建的键
    foreach ($n in $regNames) {
        try { Remove-ItemProperty -LiteralPath $hkcuKey -Name $n -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($createdKey) {
        try {
            $left = @((Get-ItemProperty -LiteralPath $hkcuKey -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })
            if ($left.Count -eq 0) { Remove-Item -LiteralPath $hkcuKey -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'B131 全部通过' -ForegroundColor Green
    exit 0
} else {
    Write-Host "B131 有 $fail 项失败" -ForegroundColor Red
    exit 1
}
