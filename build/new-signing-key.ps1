# 生成签名密钥对（一次性；私钥不进仓库）
#   私钥：%LOCALAPPDATA%\PerfCapture\keys\update-signing-private.xml   （只留本机，绝不提交）
#   公钥：%LOCALAPPDATA%\PerfCapture\keys\update-signing-public.xml    （同时硬编码进 src\app\70-Updates.ps1）
# 用法：powershell -NoProfile -File build\new-signing-key.ps1 [-Force]

param([switch]$Force)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$keyDir = Join-Path $env:LOCALAPPDATA 'PerfCapture\keys'
New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
$priv = Join-Path $keyDir 'update-signing-private.xml'
$pub = Join-Path $keyDir 'update-signing-public.xml'

if ((Test-Path $priv) -and -not $Force) {
    Write-Host "私钥已存在，未覆盖：$priv" -ForegroundColor Yellow
    Write-Host "确实要换钥匙请加 -Force（换钥匙后旧清单的签名会全部失效，且已发布的客户端无法验证新清单）" -ForegroundColor Yellow
    exit 0
}

$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
$rsa.PersistKeyInCsp = $false
[IO.File]::WriteAllText($priv, $rsa.ToXmlString($true), (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($pub, $rsa.ToXmlString($false), (New-Object Text.UTF8Encoding($false)))
$mod = $rsa.ExportParameters($false).Modulus
$rsa.Dispose()
$fp = ([System.Security.Cryptography.SHA256]::Create().ComputeHash($mod) | ForEach-Object { $_.ToString('x2') }) -join ''

Write-Host "私钥: $priv"
Write-Host "公钥: $pub"
Write-Host ("密钥指纹 SHA-256: {0}" -f $fp)
Write-Host ''
Write-Host '下一步：把公钥 XML 覆盖到 src\app\70-Updates.ps1 的 $script:UpdatePublicKeyXml' -ForegroundColor Cyan
Write-Host '（本机这把已经写进去了，换钥匙时才需要同步）'
