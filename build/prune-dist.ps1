# dist 产物清理：只保留最近 N 个发布版本的安装包。
#
# 规则见 AGENTS.md「发布决策」：dist 下只放最近 3 个发布版本的产物；
# 更早的版本从本地清掉（GitHub Release 与 updates 分支历史仍可回溯），避免工作区无限膨胀。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File build\prune-dist.ps1              # 预览
#   powershell -NoProfile -ExecutionPolicy Bypass -File build\prune-dist.ps1 -Apply       # 执行
#   powershell -NoProfile -ExecutionPolicy Bypass -File build\prune-dist.ps1 -Apply -Keep 5
#
# 只按**版本号**排序（不看时间戳）：旧版本被重新 touch 也不会挤掉新版本。
# 任何删除都限制在 dist 目录内，且文件名必须匹配 PerfCapture 产物命名。
param(
    [string]$DistRoot = '',
    [int]$Keep = 3,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

if (-not $DistRoot) { $DistRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'dist' }
if (-not (Test-Path -LiteralPath $DistRoot)) { Write-Host "dist 目录不存在：$DistRoot"; exit 0 }
if ($Keep -lt 1) { throw 'Keep 必须 ≥ 1（拒绝把 dist 清空）' }

$distFull = [IO.Path]::GetFullPath($DistRoot).TrimEnd('\')

function Get-VerKey([string]$v) {
    $p = @($v -split '\.' | ForEach-Object { $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 } })
    while ($p.Count -lt 3) { $p += 0 }
    return ($p[0] * 1000000 + $p[1] * 1000 + $p[2])
}

# 版本 → 该版本的产物路径（目录 / zip / Setup exe），三种命名都认
$byVer = @{}
foreach ($item in @(Get-ChildItem -LiteralPath $distFull -Force -ErrorAction SilentlyContinue)) {
    $m = [regex]::Match($item.Name, '^PerfCapture(?:-Setup)?-(\d+\.\d+\.\d+)(?:\.(?:exe|zip))?$')
    if (-not $m.Success) { continue }
    $v = $m.Groups[1].Value
    if (-not $byVer.ContainsKey($v)) { $byVer[$v] = New-Object System.Collections.Generic.List[string] }
    $byVer[$v].Add($item.FullName)
}

$ordered = @($byVer.Keys | Sort-Object -Property @{ Expression = { Get-VerKey $_ } } -Descending)
$keepList = @($ordered | Select-Object -First $Keep)
$dropList = @($ordered | Select-Object -Skip $Keep)

Write-Host "== dist 产物清理 ==" -ForegroundColor Cyan
Write-Host ("  目录: {0}" -f $distFull)
Write-Host ("  保留最近 {0} 个版本: {1}" -f $Keep, (($keepList | ForEach-Object { "v$_" }) -join ', '))

if (-not $dropList.Count) {
    Write-Host ("  ✅ 当前共 {0} 个版本，未超过上限，无需清理" -f $ordered.Count) -ForegroundColor Green
    exit 0
}

$freed = [int64]0
foreach ($v in $dropList) {
    foreach ($p in @($byVer[$v])) {
        $full = [IO.Path]::GetFullPath($p)
        if (-not $full.StartsWith($distFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host ("  ⚠ 跳过目录外路径: {0}" -f $full) -ForegroundColor Yellow
            continue
        }
        $size = 0
        if (Test-Path -LiteralPath $full -PathType Container) {
            # 目录没有 Length：递归求和（-Force 兼顾隐藏项，SilentlyContinue 避免个别文件占用把统计打断）
            try {
                $sum = (Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                if ($sum) { $size = [int64]$sum }
            } catch { }
        } else {
            try { $size = [int64](Get-Item -LiteralPath $full -Force).Length } catch { }
        }
        $freed += [int64]$size
        $mb = if ($size) { [math]::Round($size / 1MB, 1) } else { 0 }
        if ($Apply) {
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host ("  · 已删除 {0}（{1} MB）" -f (Split-Path $full -Leaf), $mb)
        } else {
            Write-Host ("  · 将删除 {0}（{1} MB）" -f (Split-Path $full -Leaf), $mb)
        }
    }
}

if ($Apply) {
    Write-Host ("  ✅ 清理 {0} 个版本，释放 {1} MB" -f $dropList.Count, [math]::Round($freed / 1MB, 1)) -ForegroundColor Green
} else {
    Write-Host ("  预览：将清理 {0} 个版本，可释放 {1} MB（加 -Apply 执行）" -f $dropList.Count, [math]::Round($freed / 1MB, 1)) -ForegroundColor Yellow
}
exit 0
