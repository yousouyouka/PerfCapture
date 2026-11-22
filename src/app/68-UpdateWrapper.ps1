# 2.1.9 / M3：jsDelivr 回退包（wrapper zip）的校验与解包。
# 只在 setup 资产全源失败后启用。这里只做「纯函数 + 受控目录清理」，
# 下载/安装/清理时机仍由 70-Updates.ps1 负责，便于探针单独驱动。

try { Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop } catch { }
try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }

function Test-UpdateAssetInfo {
    param($Asset, [string]$Kind)
    if (-not $Asset) { return $false }
    $name = [string]$Asset.name
    if (-not $name -or $name -ne (Split-Path -Leaf $name)) { return $false }
    if ([string]$Asset.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or [string]$Asset.sha256 -match '^0{64}$') { return $false }
    if (-not ([long]$Asset.size -gt 0)) { return $false }
    $urls = @($Asset.urls | Where-Object { $_ })
    if (-not $urls.Count) { return $false }
    if ($Kind -eq 'wrapper') {
        $inner = [string]$Asset.innerName
        if (-not $inner -or $inner -ne (Split-Path -Leaf $inner)) { return $false }
        if ([string]$Asset.innerSha256 -notmatch '^[0-9a-fA-F]{64}$' -or [string]$Asset.innerSha256 -match '^0{64}$') { return $false }
        if (-not ([long]$Asset.innerSize -gt 0)) { return $false }
    }
    return $true
}

function New-UpdateAssetInfo {
    param($Asset, [string]$Kind)
    if (-not (Test-UpdateAssetInfo $Asset $Kind)) { return $null }
    $urls = @()
    foreach ($u in @($Asset.urls | Where-Object { $_ })) {
        if ($urls -notcontains [string]$u) { $urls += [string]$u }
    }
    $info = [ordered]@{
        Kind = $Kind
        Name = [string]$Asset.name
        Size = [long]$Asset.size
        Sha256 = ([string]$Asset.sha256).ToLowerInvariant()
        Urls = $urls
        InnerName = ''
        InnerSize = [long]0
        InnerSha256 = ''
    }
    if ($Kind -eq 'wrapper') {
        $info.InnerName = [string]$Asset.innerName
        $info.InnerSize = [long]$Asset.innerSize
        $info.InnerSha256 = ([string]$Asset.innerSha256).ToLowerInvariant()
    }
    return $info
}

function Get-UpdateUnpackRoot {
    return [IO.Path]::GetFullPath((Join-Path $env:TEMP 'PerfCapture\updates'))
}

function Remove-UpdateUnpackDir {
    param([string]$Dir)
    if (-not $Dir) { return }
    $root = Get-UpdateUnpackRoot
    $full = ''
    try { $full = [IO.Path]::GetFullPath($Dir) } catch { return }
    # 只允许删更新目录下 unpack-<版本> 这一层，杜绝路径穿越误删。
    if (-not $full.StartsWith($root + '\unpack-', [StringComparison]::OrdinalIgnoreCase)) { return }
    try { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop } catch { }
}

function Clear-StaleUpdateUnpacks {
    $root = Get-UpdateUnpackRoot
    if (-not (Test-Path -LiteralPath $root)) { return }
    try {
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'unpack-*' -ErrorAction SilentlyContinue)) {
            Remove-UpdateUnpackDir $d.FullName
        }
    } catch { }
}

# 解包并回读内层哈希：任何一步不对都抛错，由宿主统一清理并上报。
function Expand-UpdateWrapper {
    param([string]$ZipPath, [string]$Dest, [hashtable]$Info)
    if (-not (Test-Path -LiteralPath $ZipPath)) { throw 'WRAPPER_MISSING' }
    if (-not $Info -or $Info.Kind -ne 'wrapper') { throw 'WRAPPER_META' }
    $root = Get-UpdateUnpackRoot
    $fullDest = ''
    try { $fullDest = [IO.Path]::GetFullPath($Dest) } catch { throw 'UNPACK_PATH' }
    if (-not $fullDest.StartsWith($root + '\unpack-', [StringComparison]::OrdinalIgnoreCase)) { throw 'UNPACK_PATH' }
    if (Test-Path -LiteralPath $fullDest) { Remove-UpdateUnpackDir $fullDest }
    New-Item -ItemType Directory -Path $fullDest -Force | Out-Null

    $inner = Join-Path $fullDest $Info.InnerName
    $tmp = $inner + '.part'
    $za = $null
    try {
        $za = [IO.Compression.ZipFile]::OpenRead($ZipPath)
        $entries = @($za.Entries)
        if ($entries.Count -ne 1) { throw 'WRAPPER_ENTRIES' }
        $entry = $entries[0]
        if (-not [string]::Equals($entry.FullName, $Info.InnerName, [StringComparison]::OrdinalIgnoreCase)) { throw 'WRAPPER_ENTRY_NAME' }
        $src = $entry.Open()
        $dst = [IO.File]::Create($tmp)
        try { $src.CopyTo($dst) } finally { $src.Dispose(); $dst.Dispose() }
    } catch {
        if ($_.Exception.Message -match 'WRAPPER_') { throw }
        throw 'WRAPPER_READ'
    } finally {
        if ($za) { try { $za.Dispose() } catch { } }
    }

    try {
        $size = (Get-Item -LiteralPath $tmp).Length
        $hash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($size -ne $Info.InnerSize -or $hash -ne $Info.InnerSha256) { throw 'INNER_HASH' }
        Move-Item -LiteralPath $tmp -Destination $inner -Force
    } catch {
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
        if ($_.Exception.Message -eq 'INNER_HASH') { throw }
        throw 'INNER_HASH'
    }
    return $inner
}
