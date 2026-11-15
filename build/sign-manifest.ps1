# 清单签名 / 验签（RSA-2048 + SHA-256，零第三方依赖）
#
# 用法：
#   签名：powershell -NoProfile -File build\sign-manifest.ps1 -Path updates\latest.json,updates\manifest-1.4.0.json
#   验签：powershell -NoProfile -File build\sign-manifest.ps1 -Path updates\latest.json -Verify
#
# 私钥（默认 %LOCALAPPDATA%\PerfCapture\keys\update-signing-private.xml）**绝不进仓库**；
# 公钥已硬编码在 src\app\70-Updates.ps1 的 $script:UpdatePublicKeyXml。
# 签完会在同目录生成 <文件>.sig（base64 单行）。

param(
    [Parameter(Mandatory = $true)][string[]]$Path,
    [string]$KeyPath = '',
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$keyDir = Join-Path $env:LOCALAPPDATA 'PerfCapture\keys'
if (-not $KeyPath) { $KeyPath = Join-Path $keyDir 'update-signing-private.xml' }
$pubPath = Join-Path $keyDir 'update-signing-public.xml'

foreach ($p in $Path) {
    if (-not (Test-Path $p)) { throw "找不到文件: $p" }
    $full = (Resolve-Path $p).Path
    $bytes = [IO.File]::ReadAllBytes($full)

    if ($Verify) {
        $sigFile = $full + '.sig'
        if (-not (Test-Path $sigFile)) { throw "缺少签名: $sigFile" }
        if (-not (Test-Path $pubPath)) { throw "缺少公钥: $pubPath" }
        $sig = [Convert]::FromBase64String(((Get-Content $sigFile -Raw) -replace '\s', ''))
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $rsa.PersistKeyInCsp = $false
        $rsa.FromXmlString((Get-Content $pubPath -Raw))
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $ok = $rsa.VerifyData($bytes, $sha, $sig)
        $sha.Dispose(); $rsa.Dispose()
        Write-Host ("{0}  验签 {1}" -f $p, $(if ($ok) { 'OK' } else { '失败' }))
        if (-not $ok) { exit 1 }
        continue
    }

    if (-not (Test-Path $KeyPath)) { throw "找不到私钥: $KeyPath（先用 build\new-signing-key.ps1 生成）" }
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    $rsa.PersistKeyInCsp = $false
    $rsa.FromXmlString((Get-Content $KeyPath -Raw))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $sig = $rsa.SignData($bytes, $sha)
    $sha.Dispose()

    # 打印密钥指纹前 16 位，方便核对用的是哪把钥匙（不打印私钥本身）
    $mod = $rsa.ExportParameters($false).Modulus
    $rsa.Dispose()
    $fp = ([System.Security.Cryptography.SHA256]::Create().ComputeHash($mod) | ForEach-Object { $_.ToString('x2') }) -join ''

    $sigFile = $full + '.sig'
    [IO.File]::WriteAllText($sigFile, [Convert]::ToBase64String($sig) + "`n", (New-Object Text.UTF8Encoding($false)))
    Write-Host ("{0}  已签名（{1} 字节，密钥指纹 {2}…）" -f $p, $bytes.Length, $fp.Substring(0, 16))
}
