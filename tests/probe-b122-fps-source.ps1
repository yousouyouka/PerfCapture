# B122 高频数据源探针：用 .NET MemoryMappedFile 构造符合 RTSS 官方结构的「合成共享内存」，
# dot-source 真实读取器 src\app\rtss-shm.ps1，验证解析、口径、动态偏移、失败细分与仲裁互斥。
# 本机未安装 RTSS，故用合成数据验证读取逻辑；真机端到端（真实 RTSS 帧流）需在有 RTSS 的机器上补跑。
# 所有断言非空；采不到一律 N/A（ok=$false + reason），绝不返回 0 冒充。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b122-fps-source.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }
function Near([double]$a, [double]$b, [double]$tol) { return [math]::Abs($a - $b) -le $tol }

Write-Host "== B122 高频数据源探针 ==" -ForegroundColor Cyan

# ---- 加载真实读取器 ----
. (Join-Path $root 'src\app\rtss-shm.ps1')
Assert ((Get-Command Get-RtssFrameSnapshot -ErrorAction SilentlyContinue) -ne $null) '读取器已加载（Get-RtssFrameSnapshot）' '读取器未加载'

# ---- 合成共享内存工具 ----
# 结构常量（与官方 SDK 及读取器注释一致）
# 签名 = C 多字符常量 'RTSS'：MSVC 左起打包为 0x52545353，真机 RTSS 7.3.7 首 4 字节正是 53 53 54 52。
$SIG = [int]0x52545353
$SIG_LEGACY = [int]0x53535452   # 同一串字符按内存字节序拼写的兼容写法
$VER = [int]0x0002000D          # v2.13
$ENTRY = 6000
$ARROFF = 64
$ARRSZ = 2
$TOTAL = $ARROFF + $ARRSZ * $ENTRY

function New-RtssShm([string]$name, [int]$signature = $SIG, [int]$version = $VER) {
    $mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($name, [int64]$TOTAL)
    $va = $mmf.CreateViewAccessor()
    $va.Write([int64]0x00, [int]$signature)
    $va.Write([int64]0x04, [int]$version)
    $va.Write([int64]0x08, [int]$ENTRY)
    $va.Write([int64]0x0C, [int]$ARROFF)
    $va.Write([int64]0x10, [int]$ARRSZ)
    return @{ mmf = $mmf; va = $va }
}
function Set-AppEntry($va, [int]$idx, [int]$procId, [string]$procName, [int[]]$frameTimes, [int]$t1 = 0) {
    $base = [int64]($ARROFF + $idx * $ENTRY)
    $va.Write([int64]($base + 0x000), [int]$procId)
    if ($t1 -eq 0) { $t1 = [int][System.Environment]::TickCount }
    $va.Write([int64]($base + 0x110), [int]$t1)
    $nb = [System.Text.Encoding]::ASCII.GetBytes($procName)
    for ($k = 0; $k -lt $nb.Length -and $k -lt 259; $k++) { $va.Write([int64]($base + 0x004 + $k), [byte]$nb[$k]) }
    $va.Write([int64]($base + 0x004 + $nb.Length), [byte]0)
    for ($j = 0; $j -lt $frameTimes.Count -and $j -lt 1024; $j++) {
        $va.Write([int64]($base + 0x39C + $j * 4), [int]$frameTimes[$j])
    }
}
function Close-Shm($h) { $h.va.Dispose(); $h.mmf.Dispose() }
function New-Name { 'B122_' + [guid]::NewGuid().ToString('N').Substring(0, 10) }

# ---- 1. 正常解析：FPS / 1% Low 口径（非空断言）----
# 构造 100 帧：99 帧 10000us(10ms) + 1 帧 100000us(100ms)
#   平均帧时间 = (99*10000 + 100000)/100 = 10900us  -> FPS = 1e6/10900 = 91.74
#   最慢 1% = 1 帧(100000us)                        -> 1% Low = 1e6/100000 = 10.00
$n1 = New-Name; $h1 = New-RtssShm $n1
$fts = @(); for ($i = 0; $i -lt 100; $i++) { $fts += 10000 }; $fts[0] = 100000
Set-AppEntry $h1.va 0 4242 'game.exe' $fts
try {
    $r = Get-RtssFrameSnapshot -ShmName $n1
    Assert $r.ok '正常共享内存解析成功' "解析失败：$($r.reason)"
    Assert (Near ([double]$r.fps) 91.74 0.05) "FPS 口径正确（$($r.fps) ≈ 91.74）" "FPS 口径错误：$($r.fps)"
    Assert (Near ([double]$r.fpsLow1) 10.0 0.05) "1% Low 口径正确（$($r.fpsLow1) ≈ 10）" "1% Low 口径错误：$($r.fpsLow1)"
    Assert ($r.sampleCount -eq 100) "样本数正确（$($r.sampleCount)）" "样本数错误：$($r.sampleCount)"
    Assert ($r.processName -eq 'game.exe') "进程名解析正确（$($r.processName)）" "进程名错误：$($r.processName)"
    Assert ($r.version -eq '2.13') "版本解析正确（$($r.version)）" "版本错误：$($r.version)"
    Assert ($r.source -eq 'rtss-shm') '数据来源标记为 rtss-shm' '来源标记缺失'
} finally { Close-Shm $h1 }

# ---- 1b. 兼容签名写法：0x53535452 也应被接受（曾把写法差异误判成版本不兼容）----
$n1b = New-Name; $h1b = New-RtssShm $n1b $SIG_LEGACY
Set-AppEntry $h1b.va 0 4242 'legacy.exe' (@(16667) * 60)
try {
    $r1b = Get-RtssFrameSnapshot -ShmName $n1b
    Assert ($r1b.ok) '兼容签名写法（0x53535452）被接受' "兼容签名被误判：$($r1b.detail)"
} finally { Close-Shm $h1b }

# ---- 2. 动态偏移：arrOffset / entrySize 非默认值也能遍历 ----
# 用一个自定义布局（ARROFF/ENTRY 已是合成值，与读取器默认假设不同），验证不硬编码。
$n2 = New-Name; $h2 = New-RtssShm $n2
Set-AppEntry $h2.va 1 9999 'dyn.exe' (@(16667) * 60)   # 60fps
try {
    $r2 = Get-RtssFrameSnapshot -ShmName $n2 -TargetPid 9999
    Assert $r2.ok '动态偏移遍历第二个条目成功' "动态偏移失败：$($r2.reason)"
    Assert (Near ([double]$r2.fps) 60.0 0.1) "按 PID 选条目 FPS 口径正确（$($r2.fps)）" "动态偏移 FPS 错误：$($r2.fps)"
    Assert ($r2.processName -eq 'dyn.exe') '按 PID 选中正确进程' '按 PID 选错进程'
} finally { Close-Shm $h2 }

# ---- 3. 失败细分：签名错误 / 版本过旧 / 陈旧 / 无帧，一律 N/A 不报 0 ----
$n3 = New-Name; $h3 = New-RtssShm $n3 0x12345678 $VER   # 无效签名（避开 0xDEAD0000 的 int 溢出）
try {
    $r3 = Get-RtssFrameSnapshot -ShmName $n3
    Assert (-not $r3.ok -and $r3.reason -eq 'badSignature') '签名错误 → badSignature' "签名判定错误：$($r3.reason)"
    Assert ($r3.detail -match '0x12345678') '签名错误时带回实际值（便于真机排查）' "签名错误未带回实际值：$($r3.detail)"
    Assert ($null -eq $r3.fps) '签名错误时 FPS 为 N/A（非 0）' '签名错误却给了 FPS 数值'
} finally { Close-Shm $h3 }

$n4 = New-Name; $h4 = New-RtssShm $n4 $SIG 0x00020003   # v2.3 < v2.5
try {
    $r4 = Get-RtssFrameSnapshot -ShmName $n4
    Assert (-not $r4.ok -and $r4.reason -eq 'oldVersion') '版本过旧 → oldVersion' "版本判定错误：$($r4.reason)"
    Assert ($null -eq $r4.fps) '版本过旧时 FPS 为 N/A（非 0）' '版本过旧却给了 FPS 数值'
} finally { Close-Shm $h4 }

$n5 = New-Name; $h5 = New-RtssShm $n5
$oldTick = [int]([System.Environment]::TickCount - 5000)
Set-AppEntry $h5.va 0 4242 'stale.exe' (@(10000) * 50) $oldTick
try {
    $r5 = Get-RtssFrameSnapshot -ShmName $n5
    Assert (-not $r5.ok -and $r5.reason -eq 'staleData') '数据停更 → staleData' "陈旧判定错误：$($r5.reason)"
    Assert ($null -eq $r5.fps) '停更时 FPS 为 N/A（非 0）' '停更却给了 FPS 数值'
} finally { Close-Shm $h5 }

$n6 = New-Name; $h6 = New-RtssShm $n6
Set-AppEntry $h6.va 0 4242 'nof.exe' (@(0) * 50)   # 全空缓冲
try {
    $r6 = Get-RtssFrameSnapshot -ShmName $n6
    Assert (-not $r6.ok -and $r6.reason -eq 'noFrames') '无帧样本 → noFrames' "无帧判定错误：$($r6.reason)"
    Assert ($null -eq $r6.fps) '无帧时 FPS 为 N/A（非 0）' '无帧却给了 FPS 数值'
} finally { Close-Shm $h6 }

# 共享内存不存在
$r7 = Get-RtssFrameSnapshot -ShmName ('B122_MISSING_' + [guid]::NewGuid().ToString('N').Substring(0,8))
Assert (-not $r7.ok -and $r7.reason -eq 'shmNotFound') '共享内存不存在 → shmNotFound' "缺失判定错误：$($r7.reason)"

# ---- 4. 数据源仲裁互斥：只允许 enabled 的扩展当源 ----
# 在隔离作用域 stub 宿主依赖后 dot-source 80-Extensions.ps1
$script:Root = $root
$script:DataDir = Join-Path $env:TEMP 'PerfCapture-B122'
if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
$script:LogLines = New-Object System.Collections.ArrayList
$script:UiMessages = New-Object System.Collections.ArrayList
function Write-AppLog([string]$text, [string]$lvl = 'INFO') { [void]$script:LogLines.Add($text) }
function Send-ToUi([hashtable]$payload) { [void]$script:UiMessages.Add($payload) }
function Save-Config { }
$script:Cfg = @{ extensions = @{} }
. (Join-Path $root 'src\app\80-Extensions.ps1')

Assert ((Set-FpsSource 'presentmon') -eq $true) 'presentmon 零注入基线恒可用' 'presentmon 被误拒'
$bad = Set-FpsSource 'rtss-shm'   # 未 installed（无持久化状态）→ 必须拒绝
Assert (-not $bad) '未启用的 RTSS 不能当数据源（ETW 会话互斥）' '非法数据源被接受'
$srcCode = Get-Content (Join-Path $root 'src\app\80-Extensions.ps1') -Raw -Encoding UTF8
Assert ($srcCode -match 'MetricsCtl\.fpsSource') 'Set-FpsSource 同步采样 runspace 的 fpsSource（热切换）' '未同步 Ctl.fpsSource'
$metCode = Get-Content (Join-Path $root 'src\app\35-Metrics.ps1') -Raw -Encoding UTF8
Assert ($metCode -match 'fpsRequestFallback') '采样侧有读失败自动回退钩子' '缺自动回退钩子'
Assert ($metCode -match "Stop-FpsStream.*切源瞬间|切源瞬间.*Stop-FpsStream") '切到扩展源时停掉 PresentMon（互斥）' '未停 PresentMon'

Write-Host ""
if ($fail -eq 0) { Write-Host "== B122 通过 ==" -ForegroundColor Green }
else { Write-Host "== B122 失败 $fail 项 ==" -ForegroundColor Red }
exit $fail
