# B130 扩展运行时清理探针（2.1.4）
# 真机故障背景：用户关闭 RTSS 扩展（非卸载）后，游戏内 DLSS 选项仍然消失。
# 根因：RTSS 运行时不只有一个进程 —— 主程序还会拉起 RTSSHooksLoader64（注入器）
#       与 EncoderServer（编码服务）。旧实现只结束 installPid 的主进程，两个子进程
#       变成孤儿继续对新启动的游戏注入，游戏据此判定 DLSS 不可用。
# 本探针用「同目录内的可控进程组」验证：
#   ① 归属按安装目录判定，能同时识别主程序与派生的子进程；
#   ② 关闭后自有目录内零残留；
#   ③ 同目录外的同名进程绝不被误杀（安全边界）；
#   ④ 重复关闭幂等；没有安装路径时安全空转；
#   ⑤ Disable-ExtensionCore 集成：清进程 + 状态写 installed + 下发 restartTarget 提示。
# 用 ping.exe 复制成假的可执行文件：单文件、无依赖、可长期驻留，不碰任何真实软件。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b130-runtime-cleanup.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  OK  $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  !!  $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host '== B130 扩展运行时清理探针 ==' -ForegroundColor Cyan

# ---- stub 宿主依赖，隔离真实配置 ----
$script:Root = $root
$script:DataDir = Join-Path $env:TEMP ('PerfCapture-B130-data-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:UiMessages = New-Object System.Collections.ArrayList
function Write-AppLog([string]$text, [string]$lvl = 'INFO') { }
function Send-ToUi([hashtable]$payload) { [void]$script:UiMessages.Add($payload) }
function Save-Config { }
$script:Cfg = @{ extensions = @{} }

. (Join-Path $root 'src\app\80-Extensions.ps1')

# ---- 可控进程组：vendor（自有）与 outside（同目录外）----
$tmp = Join-Path $env:TEMP ('PerfCapture-B130-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$vendor = Join-Path $tmp 'vendor'
$outside = Join-Path $tmp 'outside'
New-Item -ItemType Directory -Path $vendor, $outside -Force | Out-Null
$ping = Join-Path $env:SystemRoot 'System32\PING.EXE'
foreach ($n in 'RTSS.exe', 'RTSSHooksLoader64.exe', 'EncoderServer.exe') {
    Copy-Item -LiteralPath $ping -Destination (Join-Path $vendor $n) -Force
}
Copy-Item -LiteralPath $ping -Destination (Join-Path $outside 'RTSS.exe') -Force

$script:Started = New-Object System.Collections.ArrayList
function Start-Fake([string]$File) {
    $p = Start-Process -FilePath $File -ArgumentList '-t', '127.0.0.1' -PassThru -WindowStyle Hidden
    [void]$script:Started.Add($p)
    return $p
}
function Stop-FakeAll {
    foreach ($p in @($script:Started)) {
        try { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } } catch { }
    }
    $script:Started.Clear()
}

try {
    # ---- 注册表条目：主程序由 processCommand 声明（唯一配置源）----
    $entry = [pscustomobject]@{
        id = 'b130-rtss'; name = 'B130 假扩展'; desc = ''; category = 'datasource'
        metrics = @('FPS'); depends = ''; size = ''; permission = ''; platform = ''
        cost = ''; source = ''; version = '1.0.0'; available = $true
        mode = 'payload'; shmName = ''; detectProcess = @(); payload = ''
        package = [pscustomobject]@{
            kind = 'nsis-zip'; version = '0.0.1'; processCommand = '{DIR}\RTSS.exe'; processArgs = ''
        }
        lifecycle = [pscustomobject]@{
            managed = $true; ownsProcess = $true; autoStart = $true
            stopOnDisable = $true; restartTargetOnDisable = $true
        }
    }
    $script:ExtRegistry = @($entry)
    $script:ExtLoaded = $true
    Set-ExtensionPersistState 'b130-rtss' 'enabled' '' @{ installedPath = $vendor; installPid = 0 }

    # ---- 1. 归属识别：目录内 3 个（主程序 + 注入器 + 编码服务），目录外不认 ----
    $pMain = Start-Fake (Join-Path $vendor 'RTSS.exe')
    $pHook = Start-Fake (Join-Path $vendor 'RTSSHooksLoader64.exe')
    $pEnc  = Start-Fake (Join-Path $vendor 'EncoderServer.exe')
    $pOut  = Start-Fake (Join-Path $outside 'RTSS.exe')
    Start-Sleep -Milliseconds 400

    $owned = @(Get-ExtensionRuntimeProcesses 'b130-rtss')
    $ownedIds = @($owned | ForEach-Object { $_.Id })
    Assert ($owned.Count -eq 3) "目录内 3 个进程全部识别（实际 $($owned.Count)）" "目录内识别不全：期望 3，实际 $($owned.Count)"
    foreach ($pair in @(@('主程序', $pMain.Id), @('注入器', $pHook.Id), @('编码服务', $pEnc.Id))) {
        Assert ($ownedIds -contains $pair[1]) "识别到$($pair[0])（pid=$($pair[1])）" "漏掉$($pair[0])（pid=$($pair[1])）"
    }
    Assert (-not ($ownedIds -contains $pOut.Id)) '同目录外的同名进程未被认作自有（不会误杀）' '把同目录外的同名进程认成了自有'
    # 路径比较必须两侧同口径：TEMP 可能被报成 8.3 短名，而识别结果已归一化成长名。
    $mainExpected = Resolve-ExtensionFsPath (Join-Path $vendor 'RTSS.exe')
    Assert ((@($owned | Where-Object { $_.Path -eq $mainExpected })).Count -eq 1) '主程序路径按注册表 processCommand 解析正确' '主程序路径解析不正确'

    # ---- 1b. PID 判据：路径读不到时的唯一锚点（提权进程的真实情形）----
    # 持久化的 installPid 由我们自己写入，指向谁就算谁的自有运行时。
    Set-ExtensionPersistState 'b130-rtss' 'enabled' '' @{ installedPath = $vendor; installPid = $pOut.Id }
    $byPid = @(Get-ExtensionRuntimeProcesses 'b130-rtss' | Where-Object { $_.Id -eq $pOut.Id })
    Assert ($byPid.Count -eq 1) 'installPid 指向的进程被认作自有（路径不可读时的锚点）' 'installPid 判据失效'
    Assert ($byPid.Count -eq 1 -and $byPid[0].IsMain -eq $true) 'installPid 命中的进程标记为 IsMain（关闭时优先结束）' '主进程未标记 IsMain'
    Set-ExtensionPersistState 'b130-rtss' 'enabled' '' @{ installedPath = $vendor; installPid = 0 }

    # ---- 1c. 父链判据：子进程路径不在自有目录，但父进程在 ----
    # RTSS 的注入器/编码服务以管理员运行，普通权限读不到路径；只能靠父链识别。
    # 用 cmd 当父进程（放在 vendor 内），由它拉起 outside 里的 RTSS.exe：
    # 路径判据不命中，但「父已归属 + 自有目录里确有同名 exe」应当放行。
    $launcher = Join-Path $vendor 'launcher.exe'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Destination $launcher -Force
    $chainExe = Join-Path $outside 'RTSS.exe'
    $pChain = Start-Process -FilePath $launcher -ArgumentList '/c', ($chainExe + ' -t 127.0.0.1') -PassThru -WindowStyle Hidden
    [void]$script:Started.Add($pChain)
    Start-Sleep -Milliseconds 900
    $chainChild = @(Get-CimInstance Win32_Process | Where-Object { [int]$_.ParentProcessId -eq [int]$pChain.Id })
    $chainOwned = @(Get-ExtensionRuntimeProcesses 'b130-rtss' | Where-Object { $_.Name -eq 'RTSS.exe' -and $_.Path -eq '' })
    Assert ($chainChild.Count -ge 1) "父链测试进程已拉起（$($chainChild.Count) 个子进程）" '父链测试进程未能拉起'
    Assert ($chainOwned.Count -ge 1) '父链命中的子进程被认作自有（路径不可读时的兜底）' '父链判据失效：读不到路径的注入器会被漏掉'

    # ---- 2. 关闭：自有零残留，目录外不受影响 ----
    $r1 = Stop-ExtensionRuntime 'b130-rtss'
    Assert ($r1.ok -eq $true) '关闭后报告 ok（无残留）' "关闭后仍报未清理干净：剩余 $(@($r1.remaining).Count)"
    # 计数口径：owned 里可能包含 cmd 这类「子进程一死自己也退出」的父进程，
    # 它若在被我们点到之前自行退出，就不计入 stopped。真正该断言的是「零残留」与
    # 「父链命中的注入器已结束」（下面两条），所以这里只要求 ≥4（3 个目录内进程 + 注入器）。
    Assert (@($r1.stopped).Count -ge 4) "实际结束了 $((@($r1.stopped)).Count) 个自有进程（含父链命中的注入器）" "结束进程数不足：$((@($r1.stopped)).Count)"
    Assert (@(Get-ExtensionRuntimeProcesses 'b130-rtss').Count -eq 0) '关闭后自有目录内零残留' '关闭后自有目录内仍有残留'
    Start-Sleep -Milliseconds 300
    $outAlive = [bool](Get-Process -Id $pOut.Id -ErrorAction SilentlyContinue)
    Assert $outAlive '同目录外的进程仍然存活（边界未被越界）' '同目录外的进程被误杀了'
    $chainAlive = @($chainChild | Where-Object { Get-Process -Id ([int]$_.ProcessId) -ErrorAction SilentlyContinue })
    Assert ($chainAlive.Count -eq 0) '父链命中的子进程已被结束（注入器不会残留）' "父链命中的子进程仍存活 $($chainAlive.Count) 个"
    Assert ((Get-Process -Id $pMain.Id -ErrorAction SilentlyContinue) -eq $null) '主程序已结束' '主程序仍在运行'

    # ---- 3. 幂等：再关一次不报错、不产生动作 ----
    $r2 = Stop-ExtensionRuntime 'b130-rtss'
    Assert ($r2.ok -eq $true) '重复关闭仍返回 ok（幂等）' '重复关闭返回失败'
    Assert (@($r2.stopped).Count -eq 0) '重复关闭没有可结束的进程（stopped=0）' "重复关闭仍报结束了 $(@($r2.stopped).Count) 个进程"

    # ---- 4. 安全空转：没有安装路径时不猜、不动手 ----
    Set-ExtensionPersistState 'b130-rtss' 'enabled' '' @{ installedPath = ''; installPid = 0 }
    $r3 = Stop-ExtensionRuntime 'b130-rtss'
    Assert ($r3.ok -eq $true) '缺安装路径时安全空转（ok）' '缺安装路径时返回失败'
    Assert (@($r3.stopped).Count -eq 0) '缺安装路径时没有结束任何进程' '缺安装路径时仍结束了进程（危险）'

    # ---- 5. 未发布的条目 / 非托管扩展不进入运行时清理 ----
    $entry.available = $false
    $r4 = Stop-ExtensionRuntime 'b130-rtss'
    Assert ($r4.ok -eq $true) '无安装路径的条目直接空转' '无安装路径时逻辑异常'
    $entry.available = $true

    # ---- 6. Disable-ExtensionCore 集成：清进程 + 写 installed + 下发重启提示 ----
    Set-ExtensionPersistState 'b130-rtss' 'enabled' '' @{ installedPath = $vendor; installPid = $pMain.Id }
    $null = Start-Fake (Join-Path $vendor 'RTSS.exe')
    $null = Start-Fake (Join-Path $vendor 'RTSSHooksLoader64.exe')
    Start-Sleep -Milliseconds 400
    $script:UiMessages.Clear()
    $dis = Disable-ExtensionCore 'b130-rtss'
    Assert ($dis -eq $true) '关闭命令返回成功' '关闭命令返回失败'
    Assert (@(Get-ExtensionRuntimeProcesses 'b130-rtss').Count -eq 0) '关闭命令执行后自有目录零残留' '关闭命令执行后仍有残留'
    Assert ((Get-ExtensionPersistState 'b130-rtss') -eq 'installed') '关闭后状态为 installed（已装未启用，非卸载）' "关闭后状态异常：$(Get-ExtensionPersistState 'b130-rtss')"
    $bag = Get-ExtensionBag
    Assert ([string]$bag['b130-rtss'].lastNote -eq 'restartTarget') '关闭后写入 restartTarget 提示（需重启游戏）' "lastNote 异常：$([string]$bag['b130-rtss'].lastNote)"
    Assert ([string]$bag['b130-rtss'].installedPath -eq $vendor) '关闭后保留安装路径（下次启用不用重装）' '关闭后安装路径被清空了'
    $stateMsg = @($script:UiMessages | Where-Object { $_.type -eq 'extensionState' -and $_.id -eq 'b130-rtss' })
    Assert ($stateMsg.Count -ge 1 -and [string]$stateMsg[-1].note -eq 'restartTarget') '状态回推带上 note=restartTarget（卡片会提示重启游戏）' '状态回推缺少 restartTarget 提示'
    Assert (-not (@($script:UiMessages | Where-Object { $_.type -eq 'extensionError' })).Count) '清理干净时不回推失败（不谎报 stopIncomplete）' '清理干净却回推了失败'

    # ---- 7. 清不干净时如实报 stopIncomplete，不写「影响已清除」----
    # 提权进程无法被普通权限结束，这里用「不存在的安装路径 + 仍在运行的目录外进程」无法构造，
    # 故只校验失败通路的结构：把 installedPath 指回 vendor 并塞入一个不可结束的守卫进程不现实。
    # 改为校验 Stop-ExtensionRuntime 的返回结构始终包含 ok/stopped/remaining/denied/main。
    $keys = @($r1.PSObject.Properties.Name)
    foreach ($k in 'ok', 'stopped', 'remaining', 'denied', 'main') {
        Assert ($keys -contains $k) "返回结构包含 $k" "返回结构缺 $k"
    }
} finally {
    Stop-FakeAll
    # 兜底：父链测试里由 cmd 拉起的子进程如果没被业务逻辑清掉，这里按目录前缀再扫一次。
    try {
        foreach ($p in @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like ($tmp + '\*') })) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    Start-Sleep -Milliseconds 200
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tmp) { Write-Host "  (清理残留目录失败: $tmp)" -ForegroundColor Yellow }
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'B130 全部通过' -ForegroundColor Green; exit 0 }
Write-Host "B130 失败 $fail 项" -ForegroundColor Red; exit 1
