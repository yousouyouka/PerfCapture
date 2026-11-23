# 配置读写：所有来自磁盘 / 前端的值都必须过校验，越界或类型不符就忽略并记日志

function New-DefaultConfig {
    [pscustomobject]@{
        theme = 'system'; seconds = 180; minimize = $true; sound = $true; skip = ''
        # 关闭窗口时缩小到托盘 / 开机自启（2.2.2）：默认都关闭，开关即生效
        closeToTray = $false; autoStart = $false
        # 采集预设：首次安装默认「专业」档（180 秒 / 预热 5 秒 / 全部采集项），与 capture-options.json 的 pro 一致
        # customBase = 自定义是从哪一档改出来的（界面显示「自定义 · 基于专业」用）
        preset = 'pro'; customBase = 'pro'; warmup = 5
        language = 'zh-CN'
        lastPid = 0; windowW = 1180; windowH = 780
        # 实时监控的「目标进程」：0 = 跟随前台窗口；>0 = 固定采这个进程（rtTargetName 只用于显示/日志）
        rtTargetPid = 0; rtTargetName = ''
        # 检查更新：auto 关掉后不再自动查；skippedVersion 是用户点过「跳过此版本」的版本号
        updateCheck = @{ auto = $true; lastCheckAt = ''; skippedVersion = '' }
        # 网络流量告警（2.2.0）：今日/本月累计（物理接口）超过阈值（MB）时提醒一次；0 = 关闭
        netAlertDayMB = 0; netAlertMonthMB = 0
        # 反向 DNS（2.2.1）：连接视图里把远程 IP 解析成主机名；默认关（隐私优先）
        netReverseDns = $false
        # 浮窗：items 是 16 项逐项勾选（老配置的 metrics 四族会一次性迁移过来，见 55-Overlay.ps1）
        overlay     = @{ visible = $false; x = -1; y = -1; opacity = 0; collapsed = $false; anchor = 'tr'; px = 100; py = 0; fontSize = 'normal'; fontColor = 'white'; layout = 'linear'; items = @('fps', 'gpuutil', 'gputemp', 'gpupower', 'ram'); hotkey = @{ ctrl = $true; alt = $true; shift = $false; key = 'M' } }
        # 扩展中心：id -> 状态对象（status/reason/installedAt/updatedAt）。老配置没有就空表。
        # 键是扩展 id，不是固定字段——载入侧必须整块遍历属性，别只挑几个键（overlay 整块丢失的教训）。
        extensions  = @{}
        # 全局热键（2.1.16 → 2.2.1）：**默认关闭**；开启但未设置时宿主用默认组合键。
        # 键位只支持 F1–F12，避免和输入法/组合键冲突；enabled=false 时不注册任何组合键
        hotkeys     = @{
            enabled = $false
            start   = @{ ctrl = $true; alt = $true; shift = $false; key = 'F9' }
            stop    = @{ ctrl = $true; alt = $true; shift = $false; key = 'F10' }
        }
    }
}

# ---------- 校验 ----------
function ConvertTo-ConfigInt {
    param($Value)
    if ($null -eq $Value) { return $null }
    $n = 0
    if ([int]::TryParse([string]$Value, [ref]$n)) { return $n }
    return $null
}

function Set-ConfigValue {
    param([string]$Key, $Value)
    if ($null -eq $Value) { return }
    switch ($Key) {
        'theme' {
            if ($Value -in @('system', 'light', 'dark')) { $script:Cfg.theme = [string]$Value }
            else { Write-AppLog ("配置 theme=$Value 非法，已忽略") 'WARN' }
        }
        'language' {
            if ($Value -in @('zh-CN', 'en-US', 'ja-JP')) { $script:Cfg.language = [string]$Value }
            else { Write-AppLog ("配置 language=$Value 非法，已忽略") 'WARN' }
        }
        'seconds' {
            $n = ConvertTo-ConfigInt $Value
            if ($null -ne $n -and $n -ge 10 -and $n -le 1800) { $script:Cfg.seconds = $n }
            else { Write-AppLog ("配置 seconds=$Value 越界（10-1800），已忽略") 'WARN' }
        }
        'minimize' { if ($Value -is [bool]) { $script:Cfg.minimize = $Value } }
        'sound'    { if ($Value -is [bool]) { $script:Cfg.sound = $Value } }
        'closeToTray' { if ($Value -is [bool]) { $script:Cfg.closeToTray = $Value } }
        'autoStart'   { if ($Value -is [bool]) { $script:Cfg.autoStart = $Value; Set-PerfAutoStart $Value } }
        'skip'     { if ($Value -is [string]) { $script:Cfg.skip = $Value } }
        'preset'   {
            # 只接受清单里存在的档位；空串 = 自定义
            if ($Value -is [string] -and ($Value -eq '' -or $Value -in @('quick', 'standard', 'pro'))) { $script:Cfg.preset = [string]$Value }
            else { Write-AppLog ("配置 preset=$Value 非法，已忽略") 'WARN' }
        }
        'customBase' {
            # 自定义是从哪一档改出来的：只接受三档 id，非法值退回 standard
            if ($Value -is [string] -and ($Value -in @('quick', 'standard', 'pro'))) { $script:Cfg.customBase = [string]$Value }
        }
        'warmup'   {
            $n = ConvertTo-ConfigInt $Value
            if ($null -ne $n -and $n -ge 0 -and $n -le 30) { $script:Cfg.warmup = $n }
            else { Write-AppLog ("配置 warmup=$Value 越界（0–30），已忽略") 'WARN' }
        }
        'lastPid' {
            $n = ConvertTo-ConfigInt $Value
            if ($null -ne $n -and $n -ge 0) { $script:Cfg.lastPid = $n }
        }
        'windowW' {
            $n = ConvertTo-ConfigInt $Value
            if ($null -ne $n -and $n -ge 980 -and $n -le 10000) { $script:Cfg.windowW = $n }
            else { Write-AppLog ("配置 windowW=$Value 越界，已忽略") 'WARN' }
        }
        'windowH' {
            $n = ConvertTo-ConfigInt $Value
            if ($null -ne $n -and $n -ge 640 -and $n -le 10000) { $script:Cfg.windowH = $n }
            else { Write-AppLog ("配置 windowH=$Value 越界，已忽略") 'WARN' }
        }
        { $_ -in @('netAlertDayMB', 'netAlertMonthMB') } {
            # 0 = 关闭；上限 1,000,000 MB（约 1 TB）足够任何家用场景
            $n = ConvertTo-ConfigInt $Value
            if ($null -ne $n -and $n -ge 0 -and $n -le 1000000) {
                if ($_ -eq 'netAlertDayMB') { $script:Cfg.netAlertDayMB = $n } else { $script:Cfg.netAlertMonthMB = $n }
            }
            else { Write-AppLog ("配置 $_=$Value 越界（0-1000000），已忽略") 'WARN' }
        }
        'netReverseDns' { if ($Value -is [bool]) { $script:Cfg.netReverseDns = $Value; if (Get-Command Set-NetReverseDns -ErrorAction SilentlyContinue) { Set-NetReverseDns $Value } } }
        'hotkeys' {
            # 整块校验（2.2.1：采集设置里的热键编辑随 saveSettings 走）；
            # 键名只认 F1–F12，非法保留原值并记日志；改完即时重注册
            if ($Value -isnot [pscustomobject] -and $Value -isnot [hashtable]) { return }
            $hk = $script:Cfg.hotkeys
            if ($null -ne $Value.enabled) { $hk.enabled = [bool]$Value.enabled }
            foreach ($side in 'start', 'stop') {
                $v = $Value.$side
                if ($null -eq $v) { continue }
                $key = ([string]$v.key).ToUpperInvariant()
                if ($key -match '^F([1-9]|1[0-2])$') {
                    $hk[$side] = @{ ctrl = [bool]$v.ctrl; alt = [bool]$v.alt; shift = [bool]$v.shift; key = $key }
                } else {
                    Write-AppLog ("热键 $side 的键名非法（$key），保留原值") 'WARN'
                }
            }
            if (Get-Command Register-PerfHotkeys -ErrorAction SilentlyContinue) { try { [void](Register-PerfHotkeys) } catch { } }
        }
        default { Write-AppLog ("未知配置项 $Key，已忽略") 'WARN' }
    }
}

# ---------- 开机自启（2.2.2）----------
# 只写 HKCU 的 Run 键（无需管理员、不装服务、不建计划任务）。
# 配置是唯一事实来源：启动时按配置校正一次，用户切换开关时立即生效。
function Get-PerfAutoStartCommand {
    $candidates = @(
        (Join-Path $script:Root 'PerfCapture.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\PerfCapture\PerfCapture.exe')
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return ('"' + $p + '" --autostart') }
    }
    return $null
}

function Set-PerfAutoStart {
    param([bool]$Enabled)
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    try {
        if ($Enabled) {
            $cmd = Get-PerfAutoStartCommand
            if (-not $cmd) {
                Write-AppLog '开机自启：未找到 PerfCapture.exe（开发态），未写入注册表' 'WARN'
                return
            }
            if (-not (Test-Path -LiteralPath $runKey)) { New-Item -Path $runKey -Force | Out-Null }
            Set-ItemProperty -Path $runKey -Name 'PerfCapture' -Value $cmd -Type String
            Write-AppLog ('开机自启已开启: ' + $cmd)
        } else {
            if (Test-Path -LiteralPath $runKey) {
                Remove-ItemProperty -Path $runKey -Name 'PerfCapture' -ErrorAction SilentlyContinue
            }
            Write-AppLog '开机自启已关闭'
        }
    } catch {
        Write-AppLog ('开机自启设置失败: ' + $_.Exception.Message) 'WARN'
    }
}

function Sync-PerfAutoStart {
    Set-PerfAutoStart ([bool]$script:Cfg.autoStart)
}

# ---------- 载入 ----------
$script:Cfg = New-DefaultConfig
if (Test-Path $script:CfgPath) {
    try {
        $j = Get-Content $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        # 与 60-Capture.ps1 的 saveSettings 白名单保持一致：preset / customBase / warmup
        # 以前只写不读，重启后又被默认值覆盖（用户选的档位与预热时长静默丢失）。
        foreach ($k in 'theme', 'language', 'seconds', 'minimize', 'sound', 'skip',
                       'preset', 'customBase', 'warmup', 'lastPid', 'windowW', 'windowH',
                       'netAlertDayMB', 'netAlertMonthMB', 'netReverseDns',
                       'closeToTray', 'autoStart') {
            if ($null -ne $j.$k) { Set-ConfigValue $k $j.$k }
        }
        # 实时监控目标进程（新增键，老配置没有就用默认 0 = 跟随前台）
        $rtp = ConvertTo-ConfigInt $j.rtTargetPid
        if ($null -ne $rtp -and $rtp -ge 0 -and $rtp -le 1000000) { $script:Cfg.rtTargetPid = $rtp }
        if ($null -ne $j.rtTargetName) { $script:Cfg.rtTargetName = [string]$j.rtTargetName }
        if ($null -ne $j.overlay) {
            foreach ($ok in $j.overlay.PSObject.Properties) { $script:Cfg.overlay[$ok.Name] = $ok.Value }
            # 老配置只有 metrics 四族、没有 items：删掉默认 items，交给 55-Overlay 走「族 → 项」迁移；
            # 否则用户以前选的四族会被新版本的默认 6 项顶掉。
            if ($null -ne $j.overlay.metrics -and $null -eq $j.overlay.items) {
                if ($script:Cfg.overlay -is [hashtable]) { [void]$script:Cfg.overlay.Remove('items') }
            }
        }
        # 全局热键（2.1.16）：整块读；键名只认 F1–F12，非法就保留默认并记日志。
        # 字段级覆盖而不是整块替换——老配置缺 shift 时不该把它当 false 以外的值。
        if ($null -ne $j.hotkeys) {
            if ($null -ne $j.hotkeys.enabled) { $script:Cfg.hotkeys.enabled = [bool]$j.hotkeys.enabled }
            foreach ($side in 'start', 'stop') {
                $v = $j.hotkeys.$side
                if ($null -eq $v) { continue }
                $key = ([string]$v.key).ToUpperInvariant()
                if ($key -match '^F([1-9]|1[0-2])$') {
                    $script:Cfg.hotkeys[$side] = @{ ctrl = [bool]$v.ctrl; alt = [bool]$v.alt; shift = [bool]$v.shift; key = $key }
                } else {
                    Write-AppLog ("热键 $side 的键名非法（$key），保留默认") 'WARN'
                }
            }
        }
        # 扩展状态：整块遍历属性（每个 id 一项），不做固定键挑选——否则新增扩展装过一次后重启就丢。
        # ConvertFrom-Json 对空对象返回 PSCustomObject，要把每个属性拷进 hashtable 供 80-Extensions 用。
        if ($null -ne $j.extensions) {
            foreach ($ek in $j.extensions.PSObject.Properties) {
                $v = $ek.Value
                # 状态对象可能带嵌套属性，转成 hashtable 保留（status / reason / installedAt / updatedAt）
                if ($v -is [pscustomobject]) {
                    $h = @{}
                    foreach ($vp in $v.PSObject.Properties) { $h[$vp.Name] = $vp.Value }
                    $script:Cfg.extensions[$ek.Name] = $h
                } else {
                    $script:Cfg.extensions[$ek.Name] = $v
                }
            }
        }
        Write-AppLog ('配置已载入: ' + $script:CfgPath)
    } catch {
        Write-AppLog ('配置解析失败，改用默认值: ' + $_.Exception.Message) 'ERROR'
    }
}

function Save-Config {
    try {
        $script:Cfg | ConvertTo-Json -Depth 4 | Set-Content -Path $script:CfgPath -Encoding UTF8
    } catch {
        Write-AppLog ('配置保存失败: ' + $_.Exception.Message) 'ERROR'
    }
}
