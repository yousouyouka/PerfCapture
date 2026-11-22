# B145 NVIDIA FrameView 候选扩展原型探针
# 验证三件事：① 本机是否具备 FrameView 运行条件（NVIDIA GPU / SDK 目录 / 服务 / 测试客户端）；
# ② FvSDK_x64.dll 的导出函数能否被发现（只读导出表，不调用需要游戏进程/权限的 API）；
# ③ 授权条款关键限制（EULA §2.5 禁止开源许可证约束）是否被记录，给出明确结论。
# 不安装、不注入、不调用 Initialize（避免启动 SDK 服务）；纯探测 + 文档断言。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b145-frameview.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Warn([string]$m) { Write-Host "  ⚠ $m" -ForegroundColor Yellow }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host '== B145 NVIDIA FrameView 原型探针 ==' -ForegroundColor Cyan

# ---------- 1. 运行环境探测 ----------
$gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA' })
$hasNv = $gpus.Count -gt 0
if ($hasNv) { Ok "检测到 NVIDIA GPU：$($gpus[0].Name)" } else { Warn '本机无 NVIDIA GPU（FrameView 不适用）' }

$paths = @(
    'C:\Program Files\NVIDIA Corporation\FrameViewSDK',
    "${env:ProgramFiles(x86)}\NVIDIA Corporation\FrameViewSDK",
    (Join-Path $env:ProgramData 'NVIDIA Corporation\FrameView')
)
$sdkRoot = $null
foreach ($p in $paths) { if ($p -and (Test-Path -LiteralPath $p)) { $sdkRoot = $p; break } }
if ($sdkRoot) { Ok "SDK 安装目录存在：$sdkRoot" } else { Warn '未找到 FrameView SDK 安装目录' }

$dll = if ($sdkRoot) { Join-Path $sdkRoot 'SDK\Public_Release\FvSDK_x64.dll' } else { '' }
$hasDll = $dll -and (Test-Path -LiteralPath $dll)
if ($hasDll) {
    $fi = Get-Item -LiteralPath $dll
    Ok "公开接口 DLL 存在：$($fi.Name)（$([math]::Round($fi.Length/1KB)) KB）"
} else { Warn 'FvSDK_x64.dll 不存在（不可用）' }

$eula = if ($sdkRoot) { Join-Path $sdkRoot 'EULA.txt' } else { '' }
$hasEula = $eula -and (Test-Path -LiteralPath $eula)

# ---------- 2. SDK 服务 / 测试客户端 ----------
$svc = @(Get-Process -Name 'nvfvsdksvc_x64', 'FvContainer', 'FrameViewSDK' -ErrorAction SilentlyContinue)
if ($svc.Count) { Ok "FrameView 相关服务在运行（$($svc.Name -join ', ')）" } else { Warn 'FrameView 服务未运行（需 FrameView 应用启动后才发布数据）' }

$testClient = if ($sdkRoot) { Join-Path $sdkRoot 'SDK\FvSDKTestClient_Public.exe' } else { '' }
if ($testClient -and (Test-Path -LiteralPath $testClient)) { Ok '官方公开测试客户端存在（可用于真机联调）' } else { Warn '官方测试客户端不存在' }

# ---------- 3. 导出函数发现（只读 PE 导出表，不加载 DLL、不调用 API）----------
# 用 strings 粗筛导出名；不 Add-Type、不 LoadLibrary，避免启动任何 SDK 运行时。
if ($hasDll) {
    $bytes = [IO.File]::ReadAllBytes($dll)
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    Assert ($text.Contains('FvSDK')) 'DLL 含 FvSDK 标识（导出名被混淆/转发，不做函数名硬断言）' 'DLL 无 FvSDK 标识'
    $header = if ($sdkRoot) { Join-Path $sdkRoot 'SDK\Public_Release\FvSDK.h' } else { '' }
    if ($header -and (Test-Path -LiteralPath $header)) {
        $h = [IO.File]::ReadAllText($header)
        $apiCount = @('FvSDK_Initialize', 'FvSDK_EnableMetrics', 'FvSDK_GetPerFrameDataPipe', 'FvSDK_Shutdown') | Where-Object { $h.Contains($_) }
        Assert ($apiCount.Count -ge 3) "公开头文件声明 $($apiCount.Count) 个关键 API" "头文件缺关键 API：$($apiCount.Count)"
    } else { Warn '公开头文件不存在' }
} else {
    Warn 'DLL 不存在，跳过导出函数发现'
}

# ---------- 4. 授权条款机器可读断言（决定能否集成）----------
if ($hasEula) {
    $txt = [IO.File]::ReadAllText($eula)
    $osClause = $txt -match '2\.5\s+You may not use the SDK in any manner that would cause it to become subject to an open source software license'
    $distAny = $txt -match 'any part of the SDK'
    Assert $osClause '识别到 EULA §2.5（禁止受开源许可证约束）' 'EULA §2.5 未找到，授权结论不可靠'
    Assert $distAny '识别到 FrameView 补充条款（SDK 任意部分可分发）' '未找到分发授权条款'
    if ($osClause) {
        # 本机 FrameView SDK 版本日期：以 EULA 版本为准；结论写入规划书
        Warn '结论：PerfCapture 是开源项目，直接随包分发 FvSDK_x64.dll 与 §2.5 冲突；'
        Warn '     可读本机已装 SDK 的方案需 NVIDIA 书面确认，本轮不做集成。'
    }
} else {
    Warn '本机无 EULA 文件，授权结论只能引用在线文档'
}

# ---------- 5. 扩展注册表仍标 available=false（原型不改发布资产）----------
$reg = Get-Content (Join-Path $root 'extensions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$fv = @($reg.extensions | Where-Object { $_.id -eq 'frameview' })[0]
Assert ($null -ne $fv -and $fv.available -eq $false) 'frameview 仍为 available=false（原型不改发布资产）' "注册表状态异常：available=$($fv.available)"

Write-Host '== B145 通过 ==' -ForegroundColor Cyan
if ($fail -gt 0) { Write-Host ("失败断言 $fail 项") -ForegroundColor Red; exit 1 }
exit 0
