# B132 关闭提速与「启用不重装」探针（2.1.6）
# 真机背景（2026-11-21）：
#   ① 点窗口右上角关闭要等好几秒 —— 实测 Stop-ExtensionRuntime 需 5864ms。
#      根因：本机 304 个进程里 180 个 ExecutablePath 为空，旧实现对每个进程都做 .NET 兜底解析
#      （1492ms/遍），而关闭流程要枚举 4~5 遍。
#   ② 每次点「一键启用」都显示正在安装 —— 日志证实 UI 命令直连完整供应：
#      21:08:16.974 扩展供应开始 / 21:08:22.941 供应成功，真的重跑了一遍解包+静默安装（含 UAC）。
# 本探针固定三条契约：
#   A. 关闭路径的耗时预算（复用快照 + 只解析候选文件名，且不再复现 5 秒级等待）；
#   B. -Fast（退出路径）不等待；
#   C. 启用优先复用已装副本，副本缺失才回落完整供应（绝不无条件重装）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b132-fast-close.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  OK  $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  !!  $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host '== B132 关闭提速 / 启用不重装 探针 ==' -ForegroundColor Cyan

# ---- stub 宿主依赖，隔离真实配置 ----
$script:Root = $root
$script:DataDir = Join-Path $env:TEMP ('PerfCapture-B132-data-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:UiMessages = New-Object System.Collections.ArrayList
function Write-AppLog([string]$text, [string]$lvl = 'INFO') { }
function Send-ToUi([hashtable]$payload) { [void]$script:UiMessages.Add($payload) }
function Save-Config { }
$script:ActiveFpsSource = 'presentmon'
$script:Cfg = @{ extensions = @{} }

. (Join-Path $root 'src\app\80-Extensions.ps1')
. (Join-Path $root 'src\app\85-ExtensionProvision.ps1')

# ---- 可控进程组：三个 exe 都放在「自装目录」里，路径可读，走路径判据 ----
$tmp = Join-Path $env:TEMP ('PerfCapture-B132-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$vendor = Join-Path $tmp 'vendor'
New-Item -ItemType Directory -Path $vendor -Force | Out-Null
$ping = Join-Path $env:SystemRoot 'System32\PING.EXE'
foreach ($n in 'RTSS.exe', 'RTSSHooksLoader64.exe', 'EncoderServer.exe') {
    Copy-Item -LiteralPath $ping -Destination (Join-Path $vendor $n) -Force
}
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
function Set-State([string]$Status, [int]$Pid0 = 0) {
    $script:Cfg.extensions['rtss-shm'] = [pscustomobject]@{
        status = $Status; installedPath = $vendor; installedVersion = '7.3.7'
        installPid = $Pid0; startedByUs = $true; autoStart = $true
    }
}

try {
    # ---- A1. 归属识别：三个进程全部认出（路径判据） ----
    $main = Start-Fake (Join-Path $vendor 'RTSS.exe')
    $c1 = Start-Fake (Join-Path $vendor 'RTSSHooksLoader64.exe')
    $c2 = Start-Fake (Join-Path $vendor 'EncoderServer.exe')
    Start-Sleep -Milliseconds 500
    Set-State 'enabled' ([int]$main.Id)
    $owned = @(Get-ExtensionRuntimeProcesses 'rtss-shm')
    Assert ($owned.Count -eq 3) "识别到 $($owned.Count) 个自有进程" "自有进程识别不完整：$($owned.Count)"

    # ---- A2. 「候选文件名」过滤：签名签名与短路 ----
    $names = Get-ExtensionExeNames $vendor
    Assert ($names.Contains('RTSS.EXE')) '候选文件名集合大小写不敏感' '候选文件名集合区分了大小写'
    Assert (([System.Collections.Generic.HashSet[string]]$names).Contains('EncoderServer.exe')) '候选文件名含子进程 exe' '候选文件名缺少子进程 exe'

    # ---- A3. 传空快照不再枚举进程表（调用方复用的前提） ----
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $none = @(Get-ExtensionRuntimeProcesses 'rtss-shm' -Snapshot @())
    $t0 = $sw.ElapsedMilliseconds
    Assert ($none.Count -eq 0) '空快照返回空集合' "空快照竟返回 $($none.Count) 个进程"
    Assert ($t0 -lt 300) "空快照短路耗时 ${t0}ms" "空快照仍在枚举进程表：${t0}ms"

    # ---- A4. 关闭耗时预算：旧实现真机 5864ms ----
    $sw.Restart()
    $r1 = Stop-ExtensionRuntime 'rtss-shm'
    $t1 = $sw.ElapsedMilliseconds
    Assert ($r1.ok -eq $true) '关闭后报告 ok（无残留）' "关闭后仍报未清理干净：剩余 $(@($r1.remaining).Count)"
    Assert (@($r1.stopped).Count -ge 3) "实际结束了 $((@($r1.stopped)).Count) 个自有进程" "结束进程数不足：$((@($r1.stopped)).Count)"
    Assert ($t1 -lt 2600) "关闭耗时 ${t1}ms（旧实现 5864ms）" "关闭仍然过慢：${t1}ms"

    # ---- A5. 无运行时的关闭：一次快照后立即返回 ----
    $sw.Restart()
    $r2 = Stop-ExtensionRuntime 'rtss-shm'
    $t2 = $sw.ElapsedMilliseconds
    Assert ($r2.ok -eq $true) '无运行时关闭幂等返回 ok' '无运行时关闭报告失败'
    Assert ($t2 -lt 800) "无运行时关闭 ${t2}ms" "无运行时关闭仍在多轮枚举：${t2}ms"

    # ---- B. -Fast 不等待：三项一起起，强杀后立即复核 ----
    [void](Start-Fake (Join-Path $vendor 'RTSS.exe'))
    [void](Start-Fake (Join-Path $vendor 'RTSSHooksLoader64.exe'))
    [void](Start-Fake (Join-Path $vendor 'EncoderServer.exe'))
    Start-Sleep -Milliseconds 400
    $sw.Restart()
    $r3 = Stop-ExtensionRuntime 'rtss-shm' -Fast
    $t3 = $sw.ElapsedMilliseconds
    Assert ($r3.ok -eq $true) '-Fast 同样清空运行时' '-Fast 后仍有残留'
    Assert ($t3 -lt 1500) "-Fast 耗时 ${t3}ms" "-Fast 仍在等待：${t3}ms"

    # ---- C1. 启用优先复用已装副本：绝不进完整供应 ----
    $script:CopyCalls = 0
    $script:ProvisionCalls = 0
    function Start-ExtensionCopy($Entry) { $script:CopyCalls++; return 'started' }
    function Start-ExtensionProvision { param([string]$Id, [string]$Mode = 'oneclick') $script:ProvisionCalls++; return $true }
    # 用 stub 覆盖 dot-source 进来的同名函数（同作用域后者生效）
    Set-State 'installed' 0
    $script:UiMessages.Clear()
    $ok1 = Enable-ExtensionCore 'rtss-shm'
    Assert ($ok1 -eq $true) '已装副本：启用成功' '已装副本：启用失败'
    Assert ($script:CopyCalls -eq 1) '已装副本：走了复用路径' "已装副本：复用未被执行（CopyCalls=$($script:CopyCalls)）"
    Assert ($script:ProvisionCalls -eq 0) '已装副本：没有触发下载安装（不重装）' "已装副本：仍进入了完整供应 $($script:ProvisionCalls) 次"
    $states = @($script:UiMessages | Where-Object { $_.type -eq 'extensionState' })
    Assert ($states.Count -ge 1) '复用成功回推状态（前端据此清掉「正在启动」）' '复用成功却没有回推状态，前端会卡在「正在启动」'

    # ---- C2. 副本缺失才回落完整供应 ----
    function Start-ExtensionCopy($Entry) { return 'unavailable' }
    $script:ProvisionCalls = 0
    $ok2 = Enable-ExtensionCore 'rtss-shm'
    Assert ($ok2 -eq $true) '副本缺失：回落供应并返回成功' '副本缺失：启用失败'
    Assert ($script:ProvisionCalls -eq 1) '副本缺失：进入完整供应一次' "副本缺失：供应次数异常 $($script:ProvisionCalls)"

    # ---- C3. 残留杀不掉时拒绝启动，绝不回退到重装 ----
    function Start-ExtensionCopy($Entry) { return 'blocked' }
    $script:ProvisionCalls = 0
    $ok3 = Enable-ExtensionCore 'rtss-shm'
    Assert ($ok3 -eq $false) 'blocked：启用被拒绝' 'blocked：竟然返回成功'
    Assert ($script:ProvisionCalls -eq 0) 'blocked：不重装（重装解决不了残留）' "blocked：却进入了供应 $($script:ProvisionCalls) 次"

    # ---- C4. UI 命令路由：一键启用必须经过复用判定 ----
    $script:CopyCalls = 0
    $script:ProvisionCalls = 0
    function Start-ExtensionCopy($Entry) { $script:CopyCalls++; return 'started' }
    Set-State 'installed' 0
    Invoke-ExtensionCommand @{ cmd = 'oneClickEnableExtension'; id = 'rtss-shm' }
    Assert ($script:CopyCalls -eq 1) 'oneClick 命令先尝试复用副本' 'oneClick 命令没有走复用路径'
    Assert ($script:ProvisionCalls -eq 0) 'oneClick 命令不直接重装' "oneClick 命令仍直接触发了安装 $($script:ProvisionCalls) 次"

    # ---- C5. 源码守卫：路由分支不得再直连供应 ----
    $src = Get-Content (Join-Path $root 'src\app\80-Extensions.ps1') -Raw -Encoding UTF8
    $line = [regex]::Match($src, "'oneClickEnableExtension'\s*\{[^\r\n]*")
    Assert ($line.Success -and $line.Value -match 'Enable-ExtensionCore') 'oneClick 分支指向 Enable-ExtensionCore' 'oneClick 分支没有指向 Enable-ExtensionCore'
    Assert ($line.Success -and $line.Value -notmatch 'Start-ExtensionProvision') 'oneClick 分支不再直连 Start-ExtensionProvision' 'oneClick 分支仍直连 Start-ExtensionProvision（会每次重装）'

    # ---- C6. 性能守卫：路径解析只对候选文件名执行 ----
    Assert ($src -match 'exeNames\.Contains\(\$name\)') '路径解析按候选文件名过滤' '缺少候选文件名过滤（会退化成逐进程解析）'
    Assert ($src -match '\$Snapshot') '支持复用进程快照' '缺少快照复用参数'
} finally {
    Stop-FakeAll
    Start-Sleep -Milliseconds 200
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    if (Test-Path $script:DataDir) { try { Remove-Item -LiteralPath $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'B132 全部通过' -ForegroundColor Green } else { Write-Host "B132 失败 $fail 项" -ForegroundColor Red }
exit ([int]($fail -gt 0))
