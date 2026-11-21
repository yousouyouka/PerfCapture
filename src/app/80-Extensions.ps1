# 宿主侧扩展管理（批次 C）
# 扩展一律 opt-in：注册表 extensions.json 是唯一事实来源。
# 铁律：available=false 的扩展如实拒绝安装（extensionError: notAvailable），绝不假装成功；
#       status 由注册表 + 持久化配置 + 依赖探测实时算出，不写死、不复用旧值；
#       「关闭」是真开关——断 IPC → 终止扩展进程 → 数据源回退零注入基线 → 持久化 → 回推状态，
#       不重启本工具、无需卸载，本工具侧不得残留任何采集或注入行为。
# 约定：子文件不用 $PSScriptRoot（用 $script:Root）；顶层只初始化、不调 Send-ToUi / $form。

# ---------- 脚本级状态 ----------
$script:ExtRegistry    = @()          # 规范化注册表条目
$script:ExtLoaded      = $false
$script:ExtProcesses   = @{}          # id -> Process：独立运行的扩展进程（隔离）
$script:ExtIpc         = @{}          # id -> IPC 占位（批次 D 装入真实管道/共享内存句柄）
$script:ActiveFpsSource = 'presentmon' # 采样会话仲裁：'presentmon' 或某个 enabled 扩展 id

# ---------- 注册表 ----------
function Get-ExtensionRegistry {
    if ($script:ExtLoaded) { return $script:ExtRegistry }
    $file = Join-Path $script:Root 'extensions.json'
    $list = @()
    if (-not (Test-Path $file)) {
        Write-AppLog ('扩展注册表缺失: ' + $file) 'WARN'
        $script:ExtRegistry = @(); $script:ExtLoaded = $true
        return $script:ExtRegistry
    }
    try {
        $doc = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($e in @($doc.extensions)) {
            if ($null -eq $e -or -not $e.id) { continue }
            $dproc = @()
            if ($e.detect -and $e.detect.process) { $dproc = @($e.detect.process) }
            $list += [pscustomobject]@{
                id        = [string]$e.id
                name      = [string]$e.name
                desc      = if ($e.desc) { [string]$e.desc } else { '' }
                category  = if ($e.category) { [string]$e.category } else { 'datasource' }
                metrics   = @($e.metrics)
                depends   = if ($e.depends) { [string]$e.depends } else { '' }
                size      = if ($e.size) { [string]$e.size } else { '' }
                permission= if ($e.permission) { [string]$e.permission } else { '' }
                platform  = if ($e.platform) { [string]$e.platform } else { '' }
                cost      = if ($e.cost) { [string]$e.cost } else { '' }
                source    = if ($e.source) { [string]$e.source } else { '' }
                version   = if ($e.version) { [string]$e.version } else { '' }
                available = [bool]$e.available
                mode      = if ($e.mode) { [string]$e.mode } else { 'payload' }
                shmName   = if ($e.shmName) { [string]$e.shmName } else { '' }
                detectProcess = $dproc
                payload   = if ($e.payload) { [string]$e.payload } else { '' }
                # 批次 E：package/lifecycle 来自 extensions.json，是供应层唯一配置源。
                package   = if ($e.package) { $e.package } else { $null }
                lifecycle = if ($e.lifecycle) { $e.lifecycle } else { $null }
            }
        }
        $script:ExtRegistry = $list
        $script:ExtLoaded = $true
        $na = @($list | Where-Object { -not $_.available }).Count
        Write-AppLog ('扩展注册表已加载: ' + @($list).Count + ' 项（可安装 ' + (@($list).Count - $na) + ' / 规划中 ' + $na + '）')
    } catch {
        Write-AppLog ('扩展注册表解析失败: ' + $_.Exception.Message) 'ERROR'
        $script:ExtRegistry = @(); $script:ExtLoaded = $true
    }
    return $script:ExtRegistry
}

function Get-ExtensionEntry([string]$Id) {
    foreach ($e in (Get-ExtensionRegistry)) { if ($e.id -eq $Id) { return $e } }
    return $null
}

# ---------- 持久化（Cfg.extensions，整块遍历载入见 20-Settings.ps1） ----------
function Get-ExtensionBag {
    if ($null -eq $script:Cfg.extensions) { $script:Cfg.extensions = @{} }
    return $script:Cfg.extensions
}

function Get-ExtensionPersistState([string]$Id) {
    $bag = Get-ExtensionBag
    if (-not $bag.ContainsKey($Id)) { return '' }
    $v = $bag[$Id]
    if ($null -eq $v) { return '' }
    if ($v -is [string]) { return $v }              # 兼容旧结构：直接存状态串
    if ($null -ne $v.status) { return [string]$v.status }
    return ''
}

function Set-ExtensionPersistState([string]$Id, [string]$Status, [string]$Reason = '', $Fields = $null) {
    $bag = Get-ExtensionBag
    $old = if ($bag.ContainsKey($Id)) { $bag[$Id] } else { $null }
    $installedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    if ($null -ne $old -and $old -isnot [string] -and $null -ne $old.installedAt -and [string]$old.installedAt -ne '') {
        $installedAt = [string]$old.installedAt   # 保留首次安装时间，不被停用/重启用覆盖
    }
    $obj = [ordered]@{
        status      = $Status
        reason      = $Reason
        installedAt = $installedAt
        updatedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    # 供应层字段（autoStart / installedPath / installPid / startedByUs ...）按名字逐个写入，
    # 老配置没有这些键时不影响；键名来自调用方，不在此处硬编码扩展类型。
    if ($null -ne $Fields) {
        # 调用方可能传 hashtable 或 PSCustomObject；hashtable 的 PSObject.Properties 只有 Keys/Values，
        # 必须按字典键写，否则供应层字段会全部丢失（实测踩坑）。
        if ($Fields -is [System.Collections.IDictionary]) {
            foreach ($k in $Fields.Keys) { $obj[[string]$k] = $Fields[$k] }
        } else {
            foreach ($p in $Fields.PSObject.Properties) { $obj[$p.Name] = $p.Value }
        }
    }
    $bag[$Id] = [pscustomobject]$obj
    $script:Cfg.extensions = $bag
    try { Save-Config } catch { Write-AppLog ('扩展状态持久化失败: ' + $_.Exception.Message) 'WARN' }
}

function Clear-ExtensionPersistState([string]$Id) {
    $bag = Get-ExtensionBag
    if ($bag.ContainsKey($Id)) { [void]$bag.Remove($Id) }
    $script:Cfg.extensions = $bag
    try { Save-Config } catch { Write-AppLog ('扩展状态清除失败: ' + $_.Exception.Message) 'WARN' }
}

# ---------- 依赖探测（真实：查进程 + 外部共享内存服务是否就绪） ----------
function Test-ExtensionDependency($Entry) {
    # 批次 E：托管型扩展只看「扩展中心自己装的那一份」。本机预装的 RTSS 一律无视：
    # 不探测它的进程、不复用它的共享内存、也不把它当成依赖已满足。
    if ($Entry.package -and $Entry.package.kind) {
        $bag = Get-ExtensionBag
        $st = if ($bag.ContainsKey($Entry.id)) { $bag[$Entry.id] } else { $null }
        $installPath = if ($st -isnot [string] -and $null -ne $st) { [string]$st.installedPath } else { '' }
        $procId = if ($st -isnot [string] -and $null -ne $st) { [int]($st.installPid) } else { 0 }
        $miss = @()
        if (-not $installPath -or -not (Test-Path -LiteralPath $installPath)) { $miss += 'installMissing' }
        $proc = if ($procId -gt 0) { Get-Process -Id $procId -ErrorAction SilentlyContinue } else { $null }
        if (-not $proc) { $miss += 'ownProcessMissing' }
        elseif ($installPath -and $proc.Path) {
            $full = [IO.Path]::GetFullPath($proc.Path)
            $root = [IO.Path]::GetFullPath($installPath)
            if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $miss += 'foreignProcess' }
        }
        $shmState = ''
        if ($Entry.mode -eq 'external-shm' -and $Entry.shmName) {
            if (Get-Command Get-RtssFrameSnapshot -ErrorAction SilentlyContinue) {
                $snap = Get-RtssFrameSnapshot -ShmName $Entry.shmName
                $shmState = [string]$snap.reason
                # 依赖就绪 = 共享内存对象真的存在且能打开。签名/版本/帧数据属于「能不能用」，
                # 由状态机单独判，不在这里混进 missing，否则报错会都笼统变成「依赖未就绪」。
                if ($shmState -in @('shmNotFound', 'shmOpenFailed')) {
                    $miss += ('shm:' + $Entry.shmName)
                }
            } else { $miss += 'readerMissing' }
        }
        return [pscustomobject]@{ ok = ($miss.Count -eq 0); missing = $miss; shmState = $shmState }
    }

    $missing = @()
    foreach ($pn in @($Entry.detectProcess)) {
        if (-not $pn) { continue }
        $hit = Get-Process -Name $pn -ErrorAction SilentlyContinue
        if (-not $hit) { $missing += $pn }
    }
    # external-shm 型：除进程外还要求共享内存对象真的可打开（RTSS 开了统计服务）。
    # 只要对象存在（即便暂时 staleData/noFrames）就算依赖就绪——新鲜度由状态机单独判。
    $shmState = ''
    if ($Entry.mode -eq 'external-shm' -and $Entry.shmName) {
        if (Get-Command Get-RtssFrameSnapshot -ErrorAction SilentlyContinue) {
            $snap = Get-RtssFrameSnapshot -ShmName $Entry.shmName
            $shmState = [string]$snap.reason
            if ($snap.reason -eq 'shmNotFound' -or $snap.reason -eq 'shmOpenFailed') {
                $missing += ('shm:' + $Entry.shmName)
            }
        } else {
            $missing += 'readerMissing'
        }
    }
    return [pscustomobject]@{ ok = ($missing.Count -eq 0); missing = $missing; shmState = $shmState }
}

# ---------- 共享内存状态的语义分层（全项目唯一口径） ----------
# 待机：RTSS 服务在跑、共享内存可读，只是当前没有被统计的游戏（noEntry/noFrames/staleData）。
#       这不是故障：用户完全可以先启用扩展、再开游戏。判成 failed 会导致数据源永远切不过去。
# 故障：结构不兼容（签名/版本/布局）、读取异常、对象或依赖消失。
$script:ShmIdleReasons   = @('noEntry', 'noFrames', 'staleData')
$script:ShmBrokenReasons = @('badSignature', 'oldVersion', 'badLayout', 'readException',
                             'shmNotFound', 'shmOpenFailed', 'readerMissing')

function Test-ExtensionShmIdle([string]$Reason) {
    return ($script:ShmIdleReasons -contains $Reason)
}

function Test-ExtensionShmBroken([string]$Reason) {
    return ($script:ShmBrokenReasons -contains $Reason)
}

# 等待「刚启动的副本」真正可用：共享内存对象建好即返回，最多等 TimeoutMs。
# 复用已装副本时进程才起来几百毫秒，共享内存往往还没建好；此时立刻算状态会闪一下
# 「读取失败 / 该扩展不是可用的数据源」。轮询代替固定 sleep：通常 200ms 内就走完。
function Wait-ExtensionReady($Entry, [int]$TimeoutMs = 4000) {
    if (-not $Entry -or -not $Entry.package) { return $false }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $dep = Test-ExtensionDependency $Entry
        if ($dep.ok) { return $true }
        # 结构问题（签名 / 版本 / 布局）等再久也不会好：提前返回，交给状态机如实报错。
        if ($dep.shmState -and $dep.shmState -ne 'shmNotFound' -and (Test-ExtensionShmBroken $dep.shmState)) { return $false }
        Start-Sleep -Milliseconds 120
    }
    return $false
}

# ---------- 状态计算（细分：planned / notInstalled / installed / enabled / unsupported / failed） ----------
function Get-ExtensionStateFor($Entry) {
    # 未发布：一律规划中，不看持久化——防止旧的残留状态把未发布扩展显示成可用。
    if (-not $Entry.available) { return 'planned' }
    $st = Get-ExtensionPersistState $Entry.id
    if (-not $st) { return 'notInstalled' }
    if ($st -eq 'installed') { return 'installed' }
    if ($st -eq 'enabled') {
        # 已启用：只有「依赖消失」或「结构不兼容 / 读异常」才算失败；
        # 待机（没开游戏）保持 enabled，否则用户在游戏外点启用就永远切不过数据源。
        $dep = Test-ExtensionDependency $Entry
        if (-not $dep.ok) { return 'failed' }
        if ($Entry.mode -eq 'external-shm' -and (Test-ExtensionShmBroken $dep.shmState)) { return 'failed' }
        return 'enabled'
    }
    if ($st -eq 'unsupported') { return 'unsupported' }
    return 'failed'
}

function Get-ExtensionStateReason([string]$Id, [string]$State) {
    $bag = Get-ExtensionBag
    if ($bag.ContainsKey($Id) -and $bag[$Id] -isnot [string] -and $null -ne $bag[$Id].reason -and [string]$bag[$Id].reason -ne '') {
        return [string]$bag[$Id].reason
    }
    switch ($State) {
        'planned' { return 'notAvailable' }
        'notInstalled' { return 'notInstalled' }
        'failed' {
            # 外部共享内存型：把读取器的细分失败原因透出（不笼统写 dependencyMissing）
            $e = Get-ExtensionEntry $Id
            if ($e -and $e.mode -eq 'external-shm' -and $e.shmName -and (Get-Command Get-RtssFrameSnapshot -ErrorAction SilentlyContinue)) {
                $snap = Get-RtssFrameSnapshot -ShmName $e.shmName
                if ($snap.reason) { return [string]$snap.reason }
            }
            return 'dependencyMissing'
        }
        default { return '' }
    }
}

function Get-ExtensionStates {
    $out = New-Object System.Collections.ArrayList
    foreach ($e in (Get-ExtensionRegistry)) {
        $state = Get-ExtensionStateFor $e
        $reason = Get-ExtensionStateReason $e.id $state
        $bag = Get-ExtensionBag
        $installedAt = ''
        $autoStart = $true
        $ownVersion = ''
        $lastNote = ''
        if ($bag.ContainsKey($e.id) -and $bag[$e.id] -isnot [string] -and $null -ne $bag[$e.id]) {
            if ($null -ne $bag[$e.id].installedAt) { $installedAt = [string]$bag[$e.id].installedAt }
            if ($null -ne $bag[$e.id].autoStart) { $autoStart = [bool]$bag[$e.id].autoStart }
            if ($null -ne $bag[$e.id].installedVersion) { $ownVersion = [string]$bag[$e.id].installedVersion }
            if ($null -ne $bag[$e.id].lastNote) { $lastNote = [string]$bag[$e.id].lastNote }
        }
        [void]$out.Add([pscustomobject]@{
            id = $e.id; name = $e.name; desc = $e.desc; category = $e.category
            metrics = $e.metrics; depends = $e.depends; size = $e.size
            permission = $e.permission; platform = $e.platform; cost = $e.cost; source = $e.source
            version = $e.version; available = $e.available
            status = $state; reason = $reason; installedAt = $installedAt
            autoStart = $autoStart; installedVersion = $ownVersion; managed = [bool]$e.package
            note = $lastNote
        })
    }
    # 不要写成 return ,$out.ToArray()：函数已经输出数组对象，调用方再 @() 会二次包装成
    # [[{...}, {...}]]，JSON 里 extensions 变成嵌套数组，前端拿不到 id/name/status。
    return $out.ToArray()
}

# ---------- 向 UI 回推 ----------
function Send-ExtensionList {
    $states = @(Get-ExtensionStates)
    Send-ToUi @{ type = 'extensions'; extensions = $states; fpsSource = $script:ActiveFpsSource }
    Write-AppLog ('扩展状态已下发: ' + $states.Count + ' 项，数据源=' + $script:ActiveFpsSource)
}

function Send-ExtensionState([string]$Id) {
    $st = Get-ExtensionStateFor (Get-ExtensionEntry $Id)
    $bag = Get-ExtensionBag
    $note = ''
    if ($bag.ContainsKey($Id) -and $bag[$Id] -isnot [string] -and $null -ne $bag[$Id].lastNote) {
        $note = [string]$bag[$Id].lastNote
    }
    Send-ToUi @{ type = 'extensionState'; id = $Id; status = $st; fpsSource = $script:ActiveFpsSource; note = $note }
}

function Send-ExtensionError([string]$Id, [string]$Reason, [string]$Detail = '') {
    Send-ToUi @{ type = 'extensionError'; id = $Id; reason = $Reason; detail = $Detail }
    $line = '扩展命令被拒: ' + $Id + ' / ' + $Reason
    if ($Detail) { $line += ' / ' + $Detail }
    Write-AppLog $line 'WARN'
}

# ---------- 采样会话仲裁（与 PresentMon 互斥，见 AGENTS.md 坑） ----------
function Set-FpsSource([string]$Source) {
    if ($Source -ne 'presentmon') {
        $e = Get-ExtensionEntry $Source
        $state = if ($e) { [string](Get-ExtensionStateFor $e) } else { 'unknown' }
        if (-not $e -or -not $e.available -or $state -ne 'enabled') {
            # 带上当前真实状态：日志能直接看出是「未启用」还是「读取失败」，不再笼统一句拒绝。
            Send-ExtensionError $Source 'invalidSource' ('state=' + $state)
            return $false
        }
    }
    $script:ActiveFpsSource = $Source
    # 同步给正在运行的采样 runspace（hashtable 跨 runspace 共享引用），实现不等重启的热切换。
    if ($script:MetricsCtl) {
        $script:MetricsCtl.fpsSource = $Source
        # 顺带同步故障口径：采样侧据此区分「待机」与「真故障」。
        $script:MetricsCtl.brokenReasons = @($script:ShmBrokenReasons)
    }
    # 数据源变了，回推 UI 让卡片上的「当前数据源」标记即时刷新
    Send-ToUi @{ type = 'fpsSource'; source = $Source }
    return $true
}

# ---------- 采样链路入口：读取当前启用扩展的高频帧快照 ----------
# 供 35-Metrics.ps1 在 ActiveFpsSource != presentmon 时调用。
# 返回读取器结果（ok/reason/fps/fpsLow1/...），由采样侧决定回退与标注。
function Get-ActiveExtensionFps {
    $src = $script:ActiveFpsSource
    if ($src -eq 'presentmon' -or -not $src) { return $null }
    $e = Get-ExtensionEntry $src
    if (-not $e -or $e.mode -ne 'external-shm' -or -not $e.shmName) { return $null }
    if (-not (Get-Command Get-RtssFrameSnapshot -ErrorAction SilentlyContinue)) { return $null }
    return Get-RtssFrameSnapshot -ShmName $e.shmName
}

# ---------- 运行时归属：自有副本目录内的全部进程 ----------
# RTSS 不是一个进程：主程序还会拉起 RTSSHooksLoader64（注入器）与 EncoderServer（编码服务）。
# 只结束 installPid 会留下孤儿注入器，它继续对新启动的游戏注入 hook —— 用户看到的就是
# 「扩展已关闭，但游戏内 DLSS 选项仍然消失」。所以归属判定必须按「安装目录」而不是单个 PID。
# 边界：只认目录前缀 + 可可读的 ExecutablePath；读不到路径一律不动手，绝不误杀用户自己的进程。

# 统一路径口径：Windows 有时把进程路径报成 8.3 短名（C:\Users\YOUSOU~1\...），
# 而持久化的安装目录是长名。直接做字符串前缀会让「关闭」一个进程都匹配不到（实测踩坑）。
# Get-Item 会把短名展开成长名；路径已不存在时保留 GetFullPath 的结果。
function Resolve-ExtensionFsPath([string]$Path) {
    if (-not $Path) { return '' }
    $full = ''
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return '' }
    try {
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($item -and $item.FullName) { $full = [string]$item.FullName }
    } catch { }
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

function Get-ExtensionInstallRoot([string]$Id) {
    $bag = Get-ExtensionBag
    if (-not $bag.ContainsKey($Id)) { return '' }
    $st = $bag[$Id]
    if ($null -eq $st -or $st -is [string]) { return '' }
    return (Resolve-ExtensionFsPath ([string]$st.installedPath))
}

# ---------- 系统级注册痕迹：Vulkan 隐式层 + RTSS 安装键 ----------
# RTSS 7.3.x 运行时会把自己注册成 Vulkan 隐式层：
#   HKLM\SOFTWARE\Khronos\Vulkan\ImplicitLayers            -> ...\Vulkan\RTSSVkLayer64.json
#   HKLM\SOFTWARE\WOW6432Node\Khronos\Vulkan\ImplicitLayers -> ...\Vulkan\RTSSVkLayer32.json
# 这两条是系统级、持久的：进程退出不会撤销，游戏每次创建 Vulkan 实例都会加载它。
# 终末地在 Vulkan 下被该层 hook 后会直接隐藏 DLSS 选项（鹰角官方客服对「DLSS 选项消失」的
# 答复就指向 RTSSVkLayer64.dll）。所以「关闭」必须同时撤销注册，否则杀进程只是假关闭。
#
# 边界：只认「值名（JSON 完整路径）落在自有安装目录内」的项。
# 用户自己装的 RTSS、Steam、OBS 的层注册一律不碰。

function Get-ExtensionVulkanLayerRegistrations([string]$Root) {
    # Root 也必须归一化：调用方传进来的可能是 8.3 短名（%TEMP% 就是典型），
    # 而注册表值名展开后是长名，直接比较会一条都匹配不到。
    $rootFull = Resolve-ExtensionFsPath $Root
    if (-not $rootFull) { return @() }
    $prefix = $rootFull.TrimEnd('\') + '\'
    # 三处都扫：64 位主键、32 位视图、以及用户级（部分 overlay 只写 HKCU）。
    $targets = @(
        @{ Hive = 'HKLM'; Key = 'SOFTWARE\Khronos\Vulkan\ImplicitLayers' },
        @{ Hive = 'HKLM'; Key = 'SOFTWARE\WOW6432Node\Khronos\Vulkan\ImplicitLayers' },
        @{ Hive = 'HKCU'; Key = 'SOFTWARE\Khronos\Vulkan\ImplicitLayers' }
    )
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($t in $targets) {
        $ps = '{0}:\{1}' -f $t.Hive, $t.Key
        if (-not (Test-Path -LiteralPath $ps)) { continue }
        $props = $null
        try { $props = Get-ItemProperty -LiteralPath $ps -ErrorAction Stop } catch { continue }
        if (-not $props) { continue }
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -match '^PS') { continue }
            # 值名就是 layer JSON 的完整路径；混进短名时用统一口径展开再比。
            $full = Resolve-ExtensionFsPath ([string]$p.Name)
            if (-not $full) { continue }
            if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            [void]$out.Add([pscustomobject]@{ Hive = $t.Hive; Key = $t.Key; Path = $ps; Name = [string]$p.Name })
        }
    }
    return $out.ToArray()
}

# 删除注册表值必须走 .NET：Remove-ItemProperty -Name 会把含反斜杠的值名
# （layer JSON 的完整路径就是这样）当路径解析，实测删不掉且不报错。
function Remove-ExtensionRegistryValue([string]$Hive, [string]$Key, [string]$Name) {
    $base = if ($Hive -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
    $k = $base.OpenSubKey($Key, $true)
    if (-not $k) { throw ('keyNotFound: ' + $Hive + '\' + $Key) }
    try {
        $k.DeleteValue($Name, $false)
    } finally {
        $k.Close()
    }
}

# RTSS 还会把安装位置写进系统注册表。只有 HKLM 的 InstallDir 确实指向自有目录时，
# 才连带清理（含 HKCU 的附属键）。用户自己安装的 RTSS：InstallDir 在 Program Files 下，
# 不匹配 → 一个键都不动（用户明确要求：本机已有 RTSS 时不要碰它）。
function Get-ExtensionInstallKeyRegistrations([string]$Root) {
    $rootFull = Resolve-ExtensionFsPath $Root
    if (-not $rootFull) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    $owned = $false
    foreach ($ps in 'HKLM:\SOFTWARE\WOW6432Node\Unwinder\RTSS', 'HKLM:\SOFTWARE\Unwinder\RTSS') {
        if (-not (Test-Path -LiteralPath $ps)) { continue }
        $props = Get-ItemProperty -LiteralPath $ps -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        $dir = Resolve-ExtensionFsPath ([string]$props.InstallDir)
        if (-not $dir) { continue }
        if (-not $dir.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { continue }
        [void]$out.Add([pscustomobject]@{ Path = $ps; Kind = 'key' })
        $owned = $true
    }
    # HKCU 的 StartMenuFolder 是 RTSS 的附属痕迹，没有路径可供判归属：
    # 只有 HKLM 已确认是我们这份副本时才一并清，否则一律不碰。
    if ($owned -and (Test-Path -LiteralPath 'HKCU:\SOFTWARE\Unwinder\RTSS')) {
        [void]$out.Add([pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Unwinder\RTSS'; Kind = 'key' })
    }
    return $out.ToArray()
}

# 撤销本扩展写在系统里的注册痕迹。返回：
#   ok       全部撤掉（或本来就没有）
#   removed  实际撤销的项数
#   failed   失败项描述（无管理员权限时会落到这里，调用方必须如实上报，不得谎报「影响已清除」）
function Clear-ExtensionSystemTraces([string]$Id, [string]$Root) {
    $res = [pscustomobject]@{ ok = $true; removed = 0; failed = @() }
    if (-not $Root) { return $res }

    foreach ($r in (Get-ExtensionVulkanLayerRegistrations $Root)) {
        try {
            Remove-ExtensionRegistryValue $r.Hive $r.Key $r.Name
            $res.removed++
        } catch {
            $res.ok = $false
            $res.failed += ('Vulkan 层注册: ' + $r.Name + ' / ' + $_.Exception.Message)
        }
    }

    foreach ($k in (Get-ExtensionInstallKeyRegistrations $Root)) {
        try {
            Remove-Item -LiteralPath $k.Path -Recurse -Force -ErrorAction Stop
            $res.removed++
        } catch {
            $res.ok = $false
            $res.failed += ('安装键: ' + $k.Path + ' / ' + $_.Exception.Message)
        }
    }

    if ($res.removed -gt 0) {
        Write-AppLog ('已撤销扩展的系统级注册痕迹: ' + $Id + ' / ' + $res.removed + ' 项')
    }
    foreach ($f in $res.failed) { Write-AppLog ('撤销系统级注册失败: ' + $Id + ' / ' + $f) 'WARN' }
    return $res
}

# 主程序路径由注册表 processCommand 展开而来（唯一配置源），用于识别「先关谁」。
function Get-ExtensionMainExePath($Entry, [string]$Root) {
    if (-not $Entry -or -not $Entry.package -or -not $Root) { return '' }
    $cmd = [string]$Entry.package.processCommand
    if (-not $cmd) { return '' }
    $tokens = @{ DIR = $Root; ID = [string]$Entry.id; VERSION = [string]$Entry.package.version }
    $expanded = if (Get-Command Expand-ExtensionTemplate -ErrorAction SilentlyContinue) {
        Expand-ExtensionTemplate $cmd $tokens
    } else {
        $cmd.Replace('{DIR}', $Root).Replace('{ID}', [string]$Entry.id).Replace('{VERSION}', [string]$Entry.package.version)
    }
    if (-not $expanded) { return '' }
    return (Resolve-ExtensionFsPath $expanded)
}

# ---------- 进程快照与「候选可执行文件名」 ----------
# 性能约束（2.1.6 实测）：本机 304 个进程里有 180 个 ExecutablePath 为空（受保护进程），
# 逐个用 .NET 兜底解析路径要 1.5 秒；而关闭流程过去要枚举 4~5 遍 —— 于是「点关闭要等好几秒」。
# 只有文件名出现在自装目录里的进程才可能是我们的，其余一律不解析路径。
# 目录清单按 Root 缓存（首次 40ms 级，之后零成本），安装完成后由 Reset-ExtensionRuntimeCache 失效。
$script:ExtExeNameCache = @{}

function Reset-ExtensionRuntimeCache {
    $script:ExtExeNameCache = @{}
}

function Get-ExtensionExeNames([string]$Root) {
    # 返回 HashSet[string]（OrdinalIgnoreCase）。
    # 坑：PowerShell 会把函数返回的可枚举对象展开成字符串数组，调用方拿到的 .Contains()
    # 就退化成 IList.Contains（区分大小写），比较器白设。必须 -NoEnumerate 保留集合本身。
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (-not $Root) { Write-Output -NoEnumerate $set; return }
    # 缓存必须带失效戳：目录里新增/删除文件（安装、升级、探针往目录里补 exe）都会改变
    # 目录的 LastWriteTime。只看路径做键会把旧清单一直用下去，新出现的进程就认不到。
    $stamp = ''
    try { $stamp = [string](Get-Item -LiteralPath $Root -Force -ErrorAction Stop).LastWriteTimeUtc.Ticks } catch { }
    $hit = $script:ExtExeNameCache[$Root]
    if ($hit -and $stamp -and $hit.Stamp -eq $stamp) {
        Write-Output -NoEnumerate $hit.Set
        return
    }
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $Root -Filter '*.exe' -File -Recurse -ErrorAction SilentlyContinue)) {
            [void]$set.Add([string]$f.Name)
        }
    } catch { }
    $script:ExtExeNameCache[$Root] = @{ Set = $set; Stamp = $stamp }
    Write-Output -NoEnumerate $set
}

function Get-ExtensionProcessSnapshot {
    try { return @(Get-CimInstance Win32_Process -ErrorAction Stop) } catch { return @() }
}

# 已知 PID 是否还有活着的：只用 Get-Process（毫秒级），比重新枚举整张进程表便宜得多。
function Test-ExtensionAnyAlive($Procs) {
    foreach ($p in @($Procs)) {
        if (Get-Process -Id ([int]$p.Id) -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

# Snapshot 可选：调用方一次枚举后复用到多处，避免重复付 CIM 的开销。
function Get-ExtensionRuntimeProcesses([string]$Id, $Snapshot = $null) {
    $root = Get-ExtensionInstallRoot $Id
    if (-not $root) { return @() }
    $prefix = $root + '\'
    $exeNames = Get-ExtensionExeNames $root
    $procs = if ($null -ne $Snapshot) { @($Snapshot) } else { Get-ExtensionProcessSnapshot }
    if (-not $procs.Count) { return @() }

    # 我们自己启动的主进程 PID：关闭流程与父链识别都以它为锚点。
    $mainPid = 0
    $bag = Get-ExtensionBag
    if ($bag.ContainsKey($Id) -and $bag[$Id] -isnot [string] -and $null -ne $bag[$Id].installPid) {
        $mainPid = [int]$bag[$Id].installPid
    }

    # 种子（两条独立判据，取并集）：
    #   ① 路径判据：ExecutablePath 落在自有目录内（最可靠，但提权进程读不到路径）；
    #   ② PID 判据：持久化记录的主进程 PID（我们自己写下的，不会认错）。
    # 用普通 Hashtable 而不是 [ordered]：OrderedDictionary 会把整数键当成位置索引，
    # 传 PID 会直接抛 "Parameter 'index'"（实测踩坑）。这里也不依赖顺序。
    $owned = @{}
    foreach ($p in $procs) {
        $procId = [int]$p.ProcessId
        if ($procId -le 4) { continue }             # System Idle / System：永远不是我们的
        $name = [string]$p.Name
        $byPid = ($mainPid -gt 0 -and $procId -eq $mainPid)
        $full = ''
        # 名字不在自装目录里 → 不可能是我们的进程，连路径都不解析（性能关键）。
        if ($name -and $exeNames.Contains($name)) {
            $path = [string]$p.ExecutablePath
            if (-not $path) {
                # CIM 返回空多半是权限受限，用 .NET 再试一次；仍为空就不走路径判据（不猜、不盲杀）。
                try { $path = [string](Get-Process -Id $procId -ErrorAction Stop).Path } catch { $path = '' }
            }
            if ($path) {
                $resolved = Resolve-ExtensionFsPath $path
                if ($resolved -and $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $full = $resolved }
            }
        }
        if ($full -or $byPid) {
            $owned[$procId] = [pscustomobject]@{
                Id = $procId; Name = $name; Path = $full; IsMain = $byPid
            }
        }
    }

    # 父链扩散：RTSS 的注入器与编码服务常以管理员运行，普通权限读不到它们的路径，
    # 但它们正是「关闭后仍在注入」的元凶，不能因为读不到路径就放过。
    # 只从已归属的父进程往下扩散，并要求安装目录里确实存在同名可执行文件 ——
    # 后者是防 PID 复用的保险丝：复用的进程名不会恰好躺在我们目录里。
    for ($round = 0; $round -lt 4; $round++) {
        $added = 0
        foreach ($p in $procs) {
            $procId = [int]$p.ProcessId
            if ($owned.Contains($procId)) { continue }
            $ppid = [int]$p.ParentProcessId
            if ($ppid -le 0 -or -not $owned.Contains($ppid)) { continue }
            $name = [string]$p.Name
            if (-not $name) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf)) { continue }
            $owned[$procId] = [pscustomobject]@{ Id = $procId; Name = $name; Path = ''; IsMain = $false }
            $added++
        }
        if ($added -eq 0) { break }
    }

    return @($owned.Values)
}

# 关闭自有运行时：先请主程序正常退出（它会自己撤销注入并收尾子进程），再按
# 「主程序优先」强杀剩余项。主程序活着会重新拉起注入器，所以顺序不能反过来。
# 返回结构固定：ok / stopped / remaining / denied / main，调用方据此如实回推，不谎报「已清除」。
# -Fast：跳过「请主程序正常退出 + 等待」，直接强杀。退出/卸载用，用户此时不要等。
function Stop-ExtensionRuntime([string]$Id, [switch]$Quiet, [switch]$Fast) {
    $result = [pscustomobject]@{
        ok = $true; stopped = @(); remaining = @(); denied = @(); main = ''
    }
    $e = Get-ExtensionEntry $Id
    if (-not $e -or -not $e.package -or -not $e.package.kind) { return $result }
    $root = Get-ExtensionInstallRoot $Id
    if (-not $root) { return $result }          # 从未安装：没有自有运行时

    $mainPath = Get-ExtensionMainExePath $e $root
    $result.main = $mainPath

    # 一次快照定生死：没有自有运行时就直接返回，不为「空跑」付第二次枚举。
    $owned = @(Get-ExtensionRuntimeProcesses $Id -Snapshot (Get-ExtensionProcessSnapshot))
    if (-not $owned.Count) { return $result }

    $isMainProc = { param($p) $p.IsMain -or ($mainPath -and $p.Path -eq $mainPath) }
    $stopped = New-Object System.Collections.Generic.List[string]
    $denied  = New-Object System.Collections.Generic.List[string]

    # ① 请主程序正常退出：它会自行撤销注入、收尾子进程。
    #    等待改为自适应（最多 700ms，进程一消失立刻继续）：旧实现固定睡满 700ms，
    #    而实测 RTSS 通常 100~200ms 就退出了，剩下的全是白等。
    if (-not $Fast) {
        $closeSent = 0
        foreach ($m in @($owned | Where-Object { & $isMainProc $_ })) {
            $gp = Get-Process -Id $m.Id -ErrorAction SilentlyContinue
            if (-not $gp) { continue }
            # 只有真的发出了关闭请求才值得等：RTSS 是托盘程序，CloseMainWindow 会返回 false，
            # 此时干等 700ms 纯属浪费，直接进强杀（强杀反而避免它在退出时回写 Vulkan 层注册）。
            try { if ($gp.CloseMainWindow()) { $closeSent++ } } catch { }
        }
        # 没发出关闭请求（主程序路径不可读且没有 PID 锚点）就不该干等，直接进强杀。
        if ($closeSent -gt 0) {
            $deadline = (Get-Date).AddMilliseconds(700)
            while ((Get-Date) -lt $deadline -and (Test-ExtensionAnyAlive $owned)) {
                Start-Sleep -Milliseconds 60
            }
        }
    }

    # ② 收尾：最多两轮「复核 → 主程序优先强制结束」。每轮重新取快照，
    #    因为主程序活着会把刚被杀掉的注入器重新拉起。
    $left = @()
    $needVerify = $true
    for ($round = 1; $round -le 2; $round++) {
        $left = @(Get-ExtensionRuntimeProcesses $Id)
        if (-not $left.Count) { $needVerify = $false; break }
        $ordered = @($left | Where-Object { & $isMainProc $_ }) +
                   @($left | Where-Object { -not (& $isMainProc $_) })
        $killed = 0
        foreach ($p in $ordered) {
            if (-not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) { continue }
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
                [void]$stopped.Add($p.Name + '#' + $p.Id)
                $killed++
            } catch {
                $tag = $p.Name + '#' + $p.Id
                if (-not $denied.Contains($tag)) { [void]$denied.Add($tag) }
                if (-not $Quiet) { Write-AppLog ('结束自有扩展进程失败: ' + $tag + ' / ' + $_.Exception.Message) 'WARN' }
            }
        }
        if ($killed -eq 0) { $needVerify = $true; break }   # 杀不动：必须复核一次再定论
        Start-Sleep -Milliseconds 120
    }
    # 最后一轮杀过之后清单已过期，必须复核；杀不动时也复核，避免把「已自行退出」误报成残留。
    if ($needVerify) { $left = @(Get-ExtensionRuntimeProcesses $Id) }

    $result.stopped = $stopped.ToArray()
    $result.denied = $denied.ToArray()
    $result.remaining = @($left)
    $result.ok = (@($left).Count -eq 0)
    return $result
}

# ---------- 隔离进程框架（批次 D 装入真实 payload；本批次实现真实的启/停） ----------
function Start-ExtensionProcess($Entry) {
    if (-not $Entry.payload) { return $null }
    $src = Join-Path $script:Root $Entry.payload
    if (-not (Test-Path $src)) { return $null }
    try {
        if ($src -match '\.ps1$') {
            $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $src + '"')) -PassThru -WindowStyle Hidden
        } else {
            $p = Start-Process -FilePath $src -PassThru -WindowStyle Hidden
        }
        return $p
    } catch {
        Write-AppLog ('启动扩展进程失败: ' + $Entry.id + ' / ' + $_.Exception.Message) 'ERROR'
        return $null
    }
}

function Stop-ExtensionProcess([string]$Id, [switch]$Fast) {
    # 托管型：按「自有安装目录」清理整棵运行时进程树（主程序 + 注入器 + 编码服务）。
    # 只杀 installPid 会留下孤儿注入器继续注入游戏，等于「关了没关」。
    $e = Get-ExtensionEntry $Id
    if ($e -and $e.package -and $e.package.kind) {
        $r = Stop-ExtensionRuntime $Id -Fast:$Fast
        if ($script:ExtProcesses.ContainsKey($Id)) { [void]$script:ExtProcesses.Remove($Id) }
        if ($r.stopped.Count) {
            Write-AppLog ('已结束自有扩展进程: ' + $Id + ' / ' + ($r.stopped -join ', '))
        }
        if (-not $r.ok) {
            $left = @($r.remaining | ForEach-Object { $_.Name + '#' + $_.Id }) -join ', '
            Write-AppLog ('自有扩展进程仍有残留: ' + $Id + ' / ' + $left) 'WARN'
        }
        return $r
    }
    if ($script:ExtProcesses.ContainsKey($Id)) {
        $p = $script:ExtProcesses[$Id]
        try { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction Stop } } catch { }
        [void]$script:ExtProcesses.Remove($Id)
    }
    return [pscustomobject]@{ ok = $true; stopped = @(); remaining = @(); denied = @(); main = '' }
}

# ---------- 安装 / 启用 / 关闭 / 卸载 ----------
function Install-ExtensionCore([string]$Id) {
    $e = Get-ExtensionEntry $Id
    if (-not $e) { Send-ExtensionError $Id 'unknown'; return $false }
    if (-not $e.available) { Send-ExtensionError $Id 'notAvailable'; return $false }
    if ($e.package -and $e.package.kind) {
        if (Get-Command Start-ExtensionProvision -ErrorAction SilentlyContinue) {
            return (Start-ExtensionProvision $Id 'install')
        }
        Send-ExtensionError $Id 'provisionUnavailable'; return $false
    }
    if ($e.mode -eq 'external-shm') {
        # 外部服务型：无随包 payload 可复制。安装 = 确认用户自装的服务就绪，再登记状态。
        $dep = Test-ExtensionDependency $e
        if (-not $dep.ok) {
            # 外部共享内存型：优先透出读取器细分原因（含 shmNotFound），别笼统说"程序未运行"。
            $why = if ($dep.shmState) { $dep.shmState } else { 'dependencyMissing' }
            Send-ExtensionError $Id $why; return $false
        }
        $dst = Join-Path $script:DataDir ('extensions\' + $Id)
        try { if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null } } catch { }
        Set-ExtensionPersistState $Id 'installed'
        Send-ExtensionState $Id
        return $true
    }
    if (-not $e.payload -or -not (Test-Path (Join-Path $script:Root $e.payload))) {
        Send-ExtensionError $Id 'payloadMissing'; return $false
    }
    $dst = Join-Path $script:DataDir ('extensions\' + $Id)
    try {
        if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        Copy-Item (Join-Path $script:Root $e.payload) $dst -Force
    } catch {
        Send-ExtensionError $Id 'installFailed'; return $false
    }
    Set-ExtensionPersistState $Id 'installed'
    Send-ExtensionState $Id
    return $true
}

function Enable-ExtensionCore([string]$Id) {
    $e = Get-ExtensionEntry $Id
    if (-not $e) { Send-ExtensionError $Id 'unknown'; return $false }
    if (-not $e.available) { Send-ExtensionError $Id 'notAvailable'; return $false }
    if ($e.package -and $e.package.kind) {
        # 已安装过的副本优先直接拉起：用户点「关闭 → 启用」不该再走一遍下载安装与 UAC。
        # 三态返回：blocked 表示有杀不掉的残留（已回推错误），此时绝不能回退到重装。
        if (Get-Command Start-ExtensionCopy -ErrorAction SilentlyContinue) {
            $copy = Start-ExtensionCopy $e
            if ($copy -eq 'started') {
                # 复用路径没有供应阶段可播，必须回推状态：前端据此清掉「正在启用」并刷新卡片。
                Send-ExtensionState $Id
                Send-ExtensionList
                return $true
            }
            if ($copy -eq 'blocked') { Send-ExtensionState $Id; return $false }
        }
        if (Get-Command Start-ExtensionProvision -ErrorAction SilentlyContinue) {
            return (Start-ExtensionProvision $Id 'enable')
        }
        Send-ExtensionError $Id 'provisionUnavailable'; return $false
    }
    $st = Get-ExtensionPersistState $Id
    if ($st -eq 'enabled') { Send-ExtensionState $Id; return $true }
    if ($st -ne 'installed') { Send-ExtensionError $Id 'notInstalled'; return $false }
    $dep = Test-ExtensionDependency $e
    if (-not $dep.ok) {
        $why = if ($dep.shmState -and $dep.shmState -ne 'shmNotFound') { $dep.shmState } else { 'dependencyMissing' }
        Send-ExtensionError $Id $why; return $false
    }
    if ($e.mode -eq 'external-shm') {
        # 外部服务型：不启动子进程（RTSS 由用户自己开着）。启用=建立读取会话并切数据源。
        $script:ExtIpc[$Id] = @{ startedAt = (Get-Date); pid = 0; mode = 'external-shm'; shmName = $e.shmName }
    } else {
        $p = Start-ExtensionProcess $e
        if ($p) { $script:ExtProcesses[$Id] = $p }
        $script:ExtIpc[$Id] = @{ startedAt = (Get-Date); pid = if ($p) { $p.Id } else { 0 } }
    }
    Set-ExtensionPersistState $Id 'enabled'
    # 数据源仲裁：启用即把 FPS 源切到本扩展（PresentMon 的 ETW 会话由采样侧据此停掉）。
    [void](Set-FpsSource $Id)
    Send-ExtensionState $Id
    return $true
}

# 真关闭：用户点「关闭」后本工具侧的影响必须即时、完全消除。
function Disable-ExtensionCore([string]$Id) {
    $e = Get-ExtensionEntry $Id
    if (-not $e) { Send-ExtensionError $Id 'unknown'; return $false }
    # ① 断开 IPC
    if ($script:ExtIpc.ContainsKey($Id)) {
        $ipc = $script:ExtIpc[$Id]
        try { if ($ipc -and $ipc.stream) { $ipc.stream.Dispose() } } catch { }
        [void]$script:ExtIpc.Remove($Id)
    }
    # ② 终止扩展运行时：自有安装目录内的整棵进程树，不是只杀主进程 PID。
    #    RTSS 的注入器（RTSSHooksLoader64）是独立进程，主进程退出后它会变成孤儿继续注入游戏，
    #    这正是「关闭后游戏内 DLSS 选项仍消失」的根因。
    $runtime = Stop-ExtensionProcess $Id
    # ③ 撤销系统级注册痕迹（Vulkan 隐式层 / 安装键）。
    #    必须在进程结束之后做：RTSS 退出时有回写注册表的动作，先删会被它补回去。
    #    这一步才是「关闭后 DLSS 恢复正常」的关键——只杀进程时，层注册仍在，
    #    游戏每次以 Vulkan 启动都会重新加载它。
    $root = Get-ExtensionInstallRoot $Id
    $traces = Clear-ExtensionSystemTraces $Id $root
    # ④ 数据源回退到零注入基线
    if ($script:ActiveFpsSource -eq $Id) { [void](Set-FpsSource 'presentmon') }
    # ⑤ 持久化：已装但停用（不卸载），未装的保持未装
    $st = Get-ExtensionPersistState $Id
    if ($st) {
        # 保留供应层字段（安装目录/版本等），只把运行态标记清掉——下次启用还要靠这些路径。
        $bag = Get-ExtensionBag
        $old = if ($bag.ContainsKey($Id)) { $bag[$Id] } else { $null }
        $fields = @{}
        if ($old -isnot [string] -and $null -ne $old) {
            foreach ($p in $old.PSObject.Properties) {
                if ($p.Name -notin @('status', 'reason', 'installedAt', 'updatedAt', 'lastNote')) { $fields[$p.Name] = $p.Value }
            }
        }
        # 关闭后的用户提示由注册表声明，不在代码里判断扩展类型。
        # restartTargetOnDisable：注入型扩展关闭后，目标程序（游戏）需重启才会恢复原有图形选项。
        $restart = [bool]($e.lifecycle -and $e.lifecycle.restartTargetOnDisable)
        if ($runtime -and -not $runtime.ok) {
            # 清理失败：保留 installPid。残留进程的父进程就是它，下次清理靠这条线索；
            # 清成 0 会让下次既识别不到残留、又退化成「读不到路径就空转」。
            $fields.lastNote = 'stopIncomplete'
        } elseif ($traces -and -not $traces.ok) {
            # 进程清干净了，但系统级注册撤不掉（典型是无管理员权限）：
            # 此时游戏仍会被 Vulkan 层 hook，DLSS 不会恢复。必须如实告知，不能报「已清除」。
            $fields.lastNote = 'vulkanLayerStuck'
            $fields.installPid = 0
            $fields.startedByUs = $false
        } else {
            $fields.installPid = 0
            $fields.startedByUs = $false
            $fields.lastNote = if ($restart) { 'restartTarget' } else { '' }
        }
        Set-ExtensionPersistState $Id 'installed' '' $fields
    }
    # ⑥ 回推状态：先回状态（卡片带上提示），再回失败原因（toast 附残留明细）。
    Send-ExtensionState $Id
    if ($runtime -and -not $runtime.ok) {
        $left = @($runtime.remaining | ForEach-Object { $_.Name + '#' + $_.Id }) -join ', '
        Send-ExtensionError $Id 'stopIncomplete' $left
        Write-AppLog ('扩展已关闭但仍有残留进程: ' + $Id + ' / ' + $left) 'WARN'
        return $false
    }
    if ($traces -and -not $traces.ok) {
        # 进程没了但注册还在：游戏依旧会被 hook，DLSS 仍不恢复，必须明确告知而不是静默成功。
        $detail = @($traces.failed) -join '; '
        Send-ExtensionError $Id 'vulkanLayerStuck' $detail
        Write-AppLog ('扩展进程已结束，但系统级 Vulkan 层注册未能撤销: ' + $Id + ' / ' + $detail) 'WARN'
        return $false
    }
    Write-AppLog ('扩展已关闭（进程已清空 ' + @($runtime.stopped).Count + ' 个，系统级注册已撤销 ' + $traces.removed + ' 项）: ' + $Id)
    return $true
}

function Uninstall-ExtensionCore([string]$Id) {
    $e = Get-ExtensionEntry $Id
    if (-not $e) { Send-ExtensionError $Id 'unknown'; return $false }
    [void](Disable-ExtensionCore $Id)
    $dst = Join-Path $script:DataDir ('extensions\' + $Id)
    try { if (Test-Path $dst) { Remove-Item $dst -Recurse -Force -ErrorAction Stop } } catch { }
    Clear-ExtensionPersistState $Id
    Send-ExtensionState $Id
    Write-AppLog ('扩展已卸载: ' + $Id)
    return $true
}

# ---------- 手动导入（2.1.8）：网络彻底不通时的唯一兜底 ----------
# 只做三件事：弹文件选择框、按注册表里的 SHA-256 预检、把手选路径交给同一条供应流水线。
# 刻意不在这里解包/安装：失败与回滚必须仍走 worker 那一条路径，避免两套语义。
function Select-ExtensionPackageFile([string]$Id) {
    $e = Get-ExtensionEntry $Id
    if (-not $e) { Send-ExtensionError $Id 'notAvailable'; return }
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = '选择扩展安装包'
    $dlg.Filter = '安装包 (*.zip;*.exe)|*.zip;*.exe|所有文件 (*.*)|*.*'
    $dlg.CheckFileExists = $true
    $dlg.Multiselect = $false
    try {
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Send-ToUi @{ type = 'extensionPackagePicked'; id = $Id; path = $dlg.FileName; name = (Split-Path -Leaf $dlg.FileName) }
        } else {
            Send-ToUi @{ type = 'extensionPackagePickCancelled'; id = $Id }
        }
    } finally {
        $dlg.Dispose()
    }
}

# 预检：文件存在、大小不超过 maxBytes、SHA-256 与注册表一致。
# 预检失败不启动供应（省掉一次「装到一半才报哈希不符」），但结论与 worker 的判定口径完全一致。
function Test-ExtensionPackageFile([string]$Id, [string]$Path) {
    $e = Get-ExtensionEntry $Id
    if (-not $e -or -not $e.package) { return @{ ok = $false; reason = 'notAvailable'; detail = '' } }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @{ ok = $false; reason = 'localPackageMissing'; detail = [string]$Path } }
    $maxBytes = if ($e.package.maxBytes) { [int64]$e.package.maxBytes } else { 134217728 }
    $size = 0
    try { $size = (Get-Item -LiteralPath $Path).Length } catch { return @{ ok = $false; reason = 'localPackageMissing'; detail = [string]$Path } }
    if ($size -le 0) { return @{ ok = $false; reason = 'localPackageMissing'; detail = '文件为空' } }
    if ($size -gt $maxBytes) { return @{ ok = $false; reason = 'archiveTooLarge'; detail = "$size > $maxBytes" } }
    $want = ([string]$e.package.sha256).ToUpperInvariant()
    if ($want -match '^[0-9A-F]{64}$') {
        $actual = ''
        try { $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() } catch { }
        if ($actual -ne $want) {
            return @{ ok = $false; reason = 'hashMismatch'; detail = ('期望 ' + $want.Substring(0, 12) + '…，实际 ' + $(if ($actual) { $actual.Substring(0, 12) + '…' } else { '读取失败' }) + '；请选择与当前版本匹配的压缩包') }
        }
    }
    return @{ ok = $true; reason = ''; detail = '' }
}

function Import-ExtensionPackage([string]$Id, [string]$Path) {
    $check = Test-ExtensionPackageFile $Id $Path
    if (-not $check.ok) {
        Write-AppLog ("手动导入被拒绝（$($check.reason)）: $Path") 'WARN'
        Send-ExtensionError $Id $check.reason $check.detail
        return
    }
    Write-AppLog ("手动导入安装包: $Path")
    [void](Start-ExtensionProvision $Id 'import' $Path)
}

# ---------- 命令分发（由 60-Capture.ps1 的 Handle-UiMessage 调用） ----------
# 注意：oneClickEnableExtension 必须走 Enable-ExtensionCore，不能直接进 Start-ExtensionProvision。
# 后者是无条件完整供应（下载→校验→解包→静默安装→配置→启动），对「已装副本」等于重装一次：
# 用户每点一次启用都要等一轮安装、重看「正在安装」，elevateInstall 还会再弹一次 UAC。
# Enable-ExtensionCore 先尝试复用已装副本，只有副本缺失时才回落到完整供应。
function Invoke-ExtensionCommand($Msg) {
    switch ($Msg.cmd) {
        'listExtensions'           { Send-ExtensionList }
        'refreshExtensionStatus'   { Send-ExtensionList; Send-ToUi @{ type = 'status'; text = '扩展状态已刷新' } }
        'oneClickEnableExtension'  { [void](Enable-ExtensionCore ([string]$Msg.id)) }
        'installExtension'         { [void](Install-ExtensionCore ([string]$Msg.id)) }
        'enableExtension'          { [void](Enable-ExtensionCore ([string]$Msg.id)) }
        'disableExtension'         { [void](Disable-ExtensionCore ([string]$Msg.id)) }
        # 取消供应（E2）：只置取消信号，回滚由 worker 在阶段边界/下载循环里完成——
        # 与失败共用同一条回滚路径，不会留下半个目录或半个 .part。
        'cancelExtensionProvision' { [void](Stop-ExtensionProvision) }
        'uninstallExtension'       { [void](Uninstall-ExtensionCore ([string]$Msg.id)) }
        # 手动导入（网络不可达兜底）：选包 → 预检哈希 → 走同一条供应流水线
        'pickExtensionPackage'     { Select-ExtensionPackageFile ([string]$Msg.id) }
        'importExtensionPackage'   { Import-ExtensionPackage ([string]$Msg.id) ([string]$Msg.path) }
        'openExtensionPage'        {
            $e = Get-ExtensionEntry ([string]$Msg.id)
            $u = if ($e -and $e.package) { [string]$e.package.pageUrl } else { '' }
            if ($u -match '^https://') { try { Start-Process $u } catch { Write-AppLog ('打开下载页失败: ' + $_.Exception.Message) 'WARN' } }
            else { Send-ExtensionError ([string]$Msg.id) 'noPageUrl' }
        }
        default                    { Send-ExtensionError '' 'unknown' }
    }
}

# ---------- 退出清理：本工具关闭时不得留下孤儿扩展进程 ----------
# 按「已安装的托管扩展」全量扫，而不是只看 ExtProcesses：上一次运行遗留的孤儿
# （主进程早退、注入器还在）不在字典里，但同样必须清掉，否则退出后它继续注入游戏。
function Stop-AllExtensionProcesses {
    foreach ($e in (Get-ExtensionRegistry)) {
        if (-not $e.package -or -not $e.package.kind) { continue }
        $root = Get-ExtensionInstallRoot $e.id
        if (-not $root) { continue }
        # 退出路径用 -Fast：用户点关闭窗口后不该再等「请主程序正常退出」的那段。
        # 强杀同样能清干净（注入已随进程消失），注册痕迹在下一步撤销。
        [void](Stop-ExtensionProcess $e.id -Fast)
        # 退出即零影响：进程结束后必须同步撤销系统级注册。
        # 否则用户关掉本工具直接去玩游戏，游戏仍会加载 RTSS 的 Vulkan 层并隐藏 DLSS 选项。
        [void](Clear-ExtensionSystemTraces $e.id $root)
    }
    foreach ($id in @($script:ExtProcesses.Keys)) {
        $e = Get-ExtensionEntry $id
        if (-not $e -or -not $e.package) { [void](Stop-ExtensionProcess $id -Fast) }
    }
}

# ---------- 启动自愈：撤销「已装但未启用」扩展的系统级注册 ----------
# 旧版本只在关闭时杀进程，不清 Vulkan 层注册。用户升级后，系统里仍残留指向副本目录的层项，
# 游戏每次以 Vulkan 启动都会加载它，DLSS 继续消失——表现为「升级了也没修好」。
# 启动时扫一遍未启用的托管扩展，把它们遗留的注册撤掉；启用中的不动（RTSS 需要它做 overlay）。
function Clear-DisabledExtensionTraces {
    $removed = 0
    foreach ($e in (Get-ExtensionRegistry)) {
        if (-not $e.package -or -not $e.package.kind) { continue }
        $root = Get-ExtensionInstallRoot $e.id
        if (-not $root) { continue }
        if ((Get-ExtensionPersistState $e.id) -eq 'enabled') { continue }
        $res = Clear-ExtensionSystemTraces $e.id $root
        $removed += [int]$res.removed
    }
    if ($removed -gt 0) {
        Write-AppLog ('启动自愈：已撤销 ' + $removed + ' 项遗留的系统级注册（未启用扩展）')
    }
    return $removed
}
