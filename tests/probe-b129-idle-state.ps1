# B129 待机/故障语义探针
# 真机故障背景：RTSS 已装好、进程在跑，但当时没有游戏在采集，读取器返回 noEntry。
# 旧逻辑把 noEntry / noFrames / staleData 一律当 failed，于是：
#   ① 启用后界面提示「该扩展不是可用的数据源」（invalidSource）；
#   ② 数据源永远切不到 RTSS —— 用户先启用、再开游戏的正常路径直接断掉。
# 本探针用合成共享内存覆盖：待机保持 enabled 且可切数据源；结构不兼容才 failed。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b129-idle-state.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host "== B129 待机/故障语义探针 ==" -ForegroundColor Cyan

# ---- stub 宿主依赖，隔离真实配置 ----
$script:Root = $root
$script:DataDir = Join-Path $env:TEMP ('PerfCapture-B129-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:UiMessages = New-Object System.Collections.ArrayList
function Write-AppLog([string]$text, [string]$lvl = 'INFO') { }
function Send-ToUi([hashtable]$payload) { [void]$script:UiMessages.Add($payload) }
function Save-Config { }
$script:Cfg = @{ extensions = @{} }

. (Join-Path $root 'src\app\rtss-shm.ps1')
. (Join-Path $root 'src\app\80-Extensions.ps1')

# ---- 合成共享内存（与官方 SDK 结构一致）----
$SIG = [int]0x52545353          # 'RTSS' 多字符常量
$VER = [int]0x0002000D          # v2.13
$SHM_ENTRY_SIZE = 6000
$ARROFF = 64
$ARRSZ = 2
$TOTAL = $ARROFF + $ARRSZ * $SHM_ENTRY_SIZE

function New-B129Shm([string]$name, [int]$signature = $SIG, [int]$version = $VER) {
    $mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($name, [int64]$TOTAL)
    $va = $mmf.CreateViewAccessor()
    $va.Write([int64]0x00, [int]$signature)
    $va.Write([int64]0x04, [int]$version)
    $va.Write([int64]0x08, [int]$SHM_ENTRY_SIZE)
    $va.Write([int64]0x0C, [int]$ARROFF)
    $va.Write([int64]0x10, [int]$ARRSZ)
    return @{ mmf = $mmf; va = $va; name = $name }
}
function Set-B129Entry($h, [int]$procId, [string]$procName, [int]$t1 = 0) {
    $base = [int64]$ARROFF
    $va = $h.va
    $va.Write([int64]($base + 0x000), [int]$procId)
    if ($t1 -eq 0) { $t1 = [int][System.Environment]::TickCount }
    $va.Write([int64]($base + 0x110), [int]$t1)
    $nb = [System.Text.Encoding]::ASCII.GetBytes($procName)
    for ($k = 0; $k -lt $nb.Length -and $k -lt 259; $k++) { $va.Write([int64]($base + 0x004 + $k), [byte]$nb[$k]) }
    for ($j = 0; $j -lt 60; $j++) { $va.Write([int64]($base + 0x39C + $j * 4), [int]16667) }
}
function Close-B129Shm($h) { $h.va.Dispose(); $h.mmf.Dispose() }
function New-B129Name { 'B129_' + [guid]::NewGuid().ToString('N').Substring(0, 10) }

# ---- 被测条目：外部共享内存型、无进程依赖（不依赖本机是否装了 RTSS）----
$entry = [pscustomobject]@{
    id = 'b129-shm'; name = 'B129'; desc = ''; category = 'datasource'; metrics = @('FPS')
    depends = ''; size = ''; permission = ''; platform = ''; cost = ''; source = ''
    version = '1.0.0'; available = $true; mode = 'external-shm'; shmName = ''
    detectProcess = @(); payload = ''; package = $null; lifecycle = $null
}
$script:ExtRegistry = @($entry)
$script:ExtLoaded = $true
Set-ExtensionPersistState 'b129-shm' 'enabled'

# ---- 1. 待机（noEntry）：必须 enabled，且能真正切换数据源 ----
$h1 = New-B129Shm (New-B129Name)
$entry.shmName = $h1.name
$r1 = Get-RtssFrameSnapshot -ShmName $h1.name
Assert ($r1.reason -eq 'noEntry') "无游戏时读取器报 noEntry（实际 $($r1.reason)）" "无游戏时读取器报错：$($r1.reason)"
Assert (Test-ExtensionShmIdle 'noEntry') 'noEntry 归入待机口径' 'noEntry 未被归入待机'
Assert ((Get-ExtensionStateFor $entry) -eq 'enabled') '待机时状态保持 enabled（不误判失败）' "待机被误判：$((Get-ExtensionStateFor $entry))"
$sw1 = Set-FpsSource 'b129-shm'
Assert ($sw1 -eq $true -and $script:ActiveFpsSource -eq 'b129-shm') '待机时数据源可以切到该扩展' '待机时数据源切不过去'
Close-B129Shm $h1

# ---- 2. 数据停更（staleData）：同样属待机 ----
$h2 = New-B129Shm (New-B129Name)
$entry.shmName = $h2.name
Set-B129Entry $h2 4242 'idle.exe' ([int]([System.Environment]::TickCount - 5000))
$r2 = Get-RtssFrameSnapshot -ShmName $h2.name
Assert ($r2.reason -eq 'staleData') "停更时读取器报 staleData（实际 $($r2.reason)）" "停更判定错误：$($r2.reason)"
Assert ((Get-ExtensionStateFor $entry) -eq 'enabled') '停更时状态保持 enabled' "停更被误判：$((Get-ExtensionStateFor $entry))"
Close-B129Shm $h2

# ---- 3. 结构不兼容（badSignature）：必须 failed，且拒绝切数据源 ----
$h3 = New-B129Shm (New-B129Name) 0x12345678
$entry.shmName = $h3.name
[void](Set-FpsSource 'presentmon')
$before = @($script:UiMessages).Count
$sw3 = Set-FpsSource 'b129-shm'
$errs = @(@($script:UiMessages)[$before..(@($script:UiMessages).Count - 1)] | Where-Object { $_.type -eq 'extensionError' })
Assert ((Get-ExtensionStateFor $entry) -eq 'failed') '签名不符时状态为 failed' "签名不符未判失败：$((Get-ExtensionStateFor $entry))"
Assert ((Get-ExtensionStateReason 'b129-shm' 'failed') -eq 'badSignature') '失败原因如实为 badSignature' "失败原因错误：$((Get-ExtensionStateReason 'b129-shm' 'failed'))"
Assert (-not $sw3 -and $script:ActiveFpsSource -eq 'presentmon') '结构不兼容时拒绝切数据源并回退基线' '不兼容竟切了数据源'
Assert ($errs.Count -eq 1 -and $errs[0].reason -eq 'invalidSource') '拒绝时回推 invalidSource' '拒绝原因未回推'
Assert ($errs[0].detail -match 'state=failed') '拒绝详情带上真实状态（不再笼统）' "拒绝详情缺失：$($errs[0].detail)"
Close-B129Shm $h3

# ---- 4. 版本过旧（oldVersion）：必须 failed ----
$h4 = New-B129Shm (New-B129Name) $SIG 0x00020003
$entry.shmName = $h4.name
Assert ((Get-ExtensionStateFor $entry) -eq 'failed') '版本过旧时状态为 failed' '版本过旧未判失败'
Assert ((Get-ExtensionStateReason 'b129-shm' 'failed') -eq 'oldVersion') '失败原因如实为 oldVersion' "失败原因错误：$((Get-ExtensionStateReason 'b129-shm' 'failed'))"
Close-B129Shm $h4

# ---- 5. 对象消失（shmNotFound）：必须 failed，且不是「待机」 ----
$entry.shmName = 'B129_MISSING_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
Assert ((Get-ExtensionStateFor $entry) -eq 'failed') '共享内存不存在时状态为 failed' '对象缺失未判失败'
Assert (-not (Test-ExtensionShmIdle 'shmNotFound')) 'shmNotFound 不属于待机' 'shmNotFound 被误归待机'

# ---- 6. 规划中扩展不受影响（未发布仍 planned）----
$planned = [pscustomobject]@{ id = 'b129-planned'; name = 'P'; available = $false; mode = 'payload'; shmName = ''; detectProcess = @(); package = $null }
$script:ExtRegistry = @($planned)
Assert ((Get-ExtensionStateFor $planned) -eq 'planned') '未发布扩展仍为 planned' '未发布扩展状态被污染'

if ($fail -eq 0) { Write-Host "`n== B129 全部通过 ==" -ForegroundColor Cyan; exit 0 }
Write-Host "`n== B129 失败 $fail 项 ==" -ForegroundColor Red
exit 1
