# 把更新清单与安装包推到 `updates` 分支（jsDelivr / raw.githubusercontent 都从这里取）
#
# 为什么要有这个分支：清单里的下载地址第一条是
#   https://cdn.jsdelivr.net/gh/<owner>/<repo>@updates/bin/<文件>
# 所以 `updates` 分支必须长期存在 bin/ 下的安装包，否则国内镜像那条路就是死链。
#
# 用法：
#   预览（默认，什么都不改）：powershell -NoProfile -File build\push-updates.ps1
#   真正执行：                powershell -NoProfile -File build\push-updates.ps1 -Yes
#   只建本地提交不推送：       powershell -NoProfile -File build\push-updates.ps1 -Yes -NoPush
#
# 安全约定：
#   - 没带 -Yes 只打印计划，**不建提交、不推送**（发布决策权在用户手里，见 AGENTS.md）。
#   - 推之前先验签：清单签名对不上就中止。
#   - 分支上只留最近 -KeepVersions 个版本的资产（默认 2），控制仓库体积。

param(
    [switch]$Yes,
    [int]$KeepVersions = 2,
    [string]$Remote = 'origin',
    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path $PSScriptRoot -Parent
$branch = 'updates'
$version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()

function Step($m) { Write-Host "· $m" }
function Ok($m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Fail($m) { Write-Host "✗ $m" -ForegroundColor Red; throw 'push-updates 中止' }

function VerKey([string]$s) {
    $p = @($s -split '\.' | ForEach-Object { [int]$_ })
    while ($p.Count -lt 3) { $p += 0 }
    return ($p[0] * 1000000 + $p[1] * 1000 + $p[2])
}

Write-Host "== 推送更新分支 ($branch) · 版本 $version ==" -ForegroundColor Cyan
if (-not $Yes) { Write-Host "  （预览模式：不会建提交也不会推送；确认无误后加 -Yes）`n" -ForegroundColor Yellow }

# ---------- 1. 待发布文件必须齐全 ----------
$setupName = "PerfCapture-Setup-$version.exe"
$zipName = "PerfCapture-$version.zip"
$assets = @(
    @{ Src = Join-Path $root "dist\$setupName"; Dst = "bin\$setupName" },
    @{ Src = Join-Path $root "dist\$zipName"; Dst = "bin\$zipName" }
)
$manifestFiles = @(
    (Join-Path $root 'updates\latest.json'),
    (Join-Path $root 'updates\latest.json.sig'),
    (Join-Path $root "updates\manifest-$version.json"),
    (Join-Path $root "updates\manifest-$version.json.sig")
)

$missing = @()
foreach ($a in $assets) { if (-not (Test-Path $a.Src)) { $missing += $a.Src } }
foreach ($m in $manifestFiles) { if (-not (Test-Path $m)) { $missing += $m } }
if ($missing.Count) { Fail ("缺少待发布文件（先跑 build\pack.ps1）：`n    " + ($missing -join "`n    ")) }
Ok '安装包与清单文件齐全'

# ---------- 2. 清单验签（推之前先自证） ----------
Step '验证清单签名'
foreach ($m in @((Join-Path $root 'updates\latest.json'), (Join-Path $root "updates\manifest-$version.json"))) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build\sign-manifest.ps1') -Path $m -Verify 2>&1
    if ($LASTEXITCODE -ne 0) { Fail ("验签失败: $m`n    " + ($out -join "`n    ")) }
}
Ok '清单签名有效'

# ---------- 3. 清单里的 size / sha256 必须对得上安装包 ----------
$man = Get-Content (Join-Path $root 'updates\latest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($man.version -ne $version) { Fail "latest.json 版本是 $($man.version)，与 VERSION($version) 不一致" }
foreach ($a in $assets) {
    $name = Split-Path $a.Src -Leaf
    $item = @($man.assets | Where-Object { $_.name -eq $name })[0]
    if (-not $item) { Fail "清单里没有 $name" }
    $size = (Get-Item $a.Src).Length
    $sha = (Get-FileHash $a.Src -Algorithm SHA256).Hash.ToLower()
    if ($size -ne $item.size) { Fail "$name 大小 $size ≠ 清单 $($item.size)（重新跑 pack.ps1）" }
    if ($sha -ne $item.sha256) { Fail "$name sha256 与清单不符（重新跑 pack.ps1）" }
}
Ok '清单的 size / sha256 与安装包一致'

# ---------- 4. 组装暂存目录（保留已有历史资产） ----------
$tmpRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$staging = Join-Path $tmpRoot ("perfcapture-updates-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$zipTmp = Join-Path $tmpRoot ("perfcapture-prev-" + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
$idx = Join-Path $tmpRoot ("perfcapture-idx-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$baseCommit = ''

try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    # 找出已有的 updates 分支（本地优先，其次远端）
    foreach ($ref in @("refs/heads/$branch", "refs/remotes/$Remote/$branch")) {
        $sha = & git -C $root rev-parse --verify --quiet $ref 2>$null
        if ($LASTEXITCODE -eq 0 -and $sha) { $baseCommit = ($sha | Out-String).Trim(); Step "已有 $ref → $($baseCommit.Substring(0, 7))"; break }
    }

    if ($baseCommit) {
        & git -C $root archive --format=zip -o $zipTmp $baseCommit 2>$null
        if ($LASTEXITCODE -ne 0) { Fail '取已有更新分支内容失败（git archive）' }
        Expand-Archive -Path $zipTmp -DestinationPath $staging -Force
        Ok '已载入更新分支现有内容'
    } else {
        Ok '更新分支还不存在，将新建'
    }

    # 放入本次版本
    New-Item -ItemType Directory -Path (Join-Path $staging 'bin') -Force | Out-Null
    foreach ($a in $assets) { Copy-Item $a.Src (Join-Path $staging $a.Dst) -Force }
    foreach ($m in $manifestFiles) { Copy-Item $m (Join-Path $staging (Split-Path $m -Leaf)) -Force }

    # 清单是**签过名的字节**：必须关掉换行转换，否则 LF→CRLF 会让签名失效
    $gattr = Join-Path $staging '.gitattributes'
    [IO.File]::WriteAllText($gattr, "* -text`n", (New-Object Text.UTF8Encoding($false)))

    # ---------- 5. 只留最近 N 个版本的资产 ----------
    $byVer = @{}
    foreach ($f in @(Get-ChildItem (Join-Path $staging 'bin') -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -match '^PerfCapture(?:-Setup)?-(\d+\.\d+\.\d+)\.(?:exe|zip)$') {
            $v = $Matches[1]
            if (-not $byVer.ContainsKey($v)) { $byVer[$v] = @() }
            $byVer[$v] += $f
        }
    }
    $ordered = @($byVer.Keys | Sort-Object -Property @{ Expression = { VerKey $_ } } -Descending)
    if ($ordered.Count -gt $KeepVersions) {
        foreach ($v in @($ordered | Select-Object -Skip $KeepVersions)) {
            foreach ($f in $byVer[$v]) { Remove-Item $f.FullName -Force; Step "清掉旧资产 $($f.Name)" }
            foreach ($suffix in @('.json', '.json.sig')) {
                $mf = Join-Path $staging "manifest-$v$suffix"
                if (Test-Path $mf) { Remove-Item $mf -Force }
            }
        }
        Ok "只保留最近 $KeepVersions 个版本"
    } else {
        Ok "分支上共 $($byVer.Keys.Count) 个版本（未超过 $KeepVersions）"
    }

    # ---------- 6. 预览清单 ----------
    $files = @(Get-ChildItem $staging -Recurse -File | Sort-Object FullName)
    Write-Host "`n  即将提交到 $branch 的内容：" -ForegroundColor Cyan
    $totalSize = 0
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($staging.Length + 1).Replace('\', '/')
        $totalSize += $f.Length
        Write-Host ("    {0,-52} {1,12:N0} B" -f $rel, $f.Length)
    }
    Write-Host ("    共 {0} 个文件 · {1:N1} MB`n" -f $files.Count, ($totalSize / 1MB))

    if (-not $Yes) {
        Write-Host '预览结束，未做任何改动。' -ForegroundColor Yellow
        Write-Host "确认后执行：`n  powershell -NoProfile -ExecutionPolicy Bypass -File build\push-updates.ps1 -Yes" -ForegroundColor Yellow
        return
    }

    # ---------- 7. 用临时 index 建提交（不碰工作区与主索引） ----------
    $old = @{ GIT_DIR = $env:GIT_DIR; GIT_WORK_TREE = $env:GIT_WORK_TREE; GIT_INDEX_FILE = $env:GIT_INDEX_FILE }
    $env:GIT_DIR = Join-Path $root '.git'
    $env:GIT_WORK_TREE = $staging
    $env:GIT_INDEX_FILE = $idx
    try {
        & git -C $staging read-tree --empty
        if ($LASTEXITCODE -ne 0) { Fail 'git read-tree 失败' }
        & git -C $staging add -A -f -- .
        if ($LASTEXITCODE -ne 0) { Fail 'git add 失败' }
        $tree = (& git -C $staging write-tree | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $tree) { Fail 'git write-tree 失败' }

        $msg = "updates: v$version ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
        $commitArgs = @('-C', $staging, 'commit-tree', $tree, '-m', $msg)
        if ($baseCommit) { $commitArgs += @('-p', $baseCommit) }
        $commit = (& git @commitArgs | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $commit) { Fail 'git commit-tree 失败' }
    } finally {
        $env:GIT_DIR = $old.GIT_DIR
        $env:GIT_WORK_TREE = $old.GIT_WORK_TREE
        $env:GIT_INDEX_FILE = $old.GIT_INDEX_FILE
        Remove-Item $idx -Force -ErrorAction SilentlyContinue
    }
    Ok "本地提交已建 $($commit.Substring(0, 7)) · $msg"

    # 自证：分支里的字节必须与本地完全一致（换行转换会毁掉签名）
    $localSize = (Get-Item (Join-Path $root 'updates\latest.json')).Length
    $blobSize = ((& git -C $root cat-file -s "${commit}:latest.json") | Out-String).Trim()
    if ($blobSize -ne "$localSize") { Fail "分支里的 latest.json 是 $blobSize 字节，本地是 $localSize 字节（换行被转换，验签会失败）" }
    Ok "清单字节一致（$localSize B）"
    & git -C $root update-ref -m "push-updates $version" "refs/heads/$branch" $commit
    if ($LASTEXITCODE -ne 0) { Fail 'git update-ref 失败' }

    if ($NoPush) {
        Write-Host "`n只建了本地分支 refs/heads/$branch，未推送（-NoPush）。" -ForegroundColor Yellow
        Write-Host "手动推送：git push $Remote $branch" -ForegroundColor Yellow
        return
    }

    # ---------- 8. 推送更新分支 ----------
    Step "推送到 $Remote/$branch"
    & git -C $root push $Remote "${branch}:${branch}"
    if ($LASTEXITCODE -ne 0) { Fail 'git push 失败（github.com:443 被挡时改用 ssh 远端）' }
    Ok "已推送 $Remote/$branch"

    # ---------- 9. 刷新 jsDelivr 缓存 ----------
    # 只清单个文件不够：清过场中出现过「清单已换新、.sig 还是旧」的错配，客户端验签必然失败。
    # 实测清整个分支（不带文件路径）才可靠。
    $owner = (& git -C $root config --get "remote.$Remote.url") -replace '.*[:/]([^/]+)/([^/]+?)(?:\.git)?$', '$1/$2'
    try {
        $purge = New-Object System.Net.Http.HttpClient
        $purge.Timeout = [TimeSpan]::FromSeconds(20)
        foreach ($p in @("https://purge.jsdelivr.net/gh/$owner@main", "https://purge.jsdelivr.net/gh/$owner@$branch")) {
            try {
                $r = $purge.GetAsync($p).GetAwaiter().GetResult()
                if ($r.IsSuccessStatusCode) { Ok "已清缓存 $($p -replace '^https://purge\.jsdelivr\.net/','')" }
                else { Write-Host "  ⚠ 清缓存返回 $([int]$r.StatusCode)：$p" -ForegroundColor Yellow }
            } catch { Write-Host "  ⚠ 清缓存失败（不影响发布，几分钟后自然过期）：$p" -ForegroundColor Yellow }
        }
        $purge.Dispose()
    } catch { Write-Host '  ⚠ 清缓存步骤跳过（缺少 System.Net.Http）' -ForegroundColor Yellow }
    Write-Host "`njsDelivr 地址（已清缓存，通常立即生效）：" -ForegroundColor Cyan
    Write-Host "  https://cdn.jsdelivr.net/gh/$owner@$branch/bin/$setupName"
    Write-Host "  https://cdn.jsdelivr.net/gh/$owner@$branch/latest.json"
    Write-Host "`nRaw：" -ForegroundColor Cyan
    Write-Host "  https://raw.githubusercontent.com/$owner/$branch/latest.json"
} catch {
    Write-Host ("✗ " + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $zipTmp) { Remove-Item $zipTmp -Force -ErrorAction SilentlyContinue }
    if (Test-Path $idx) { Remove-Item $idx -Force -ErrorAction SilentlyContinue }
}
