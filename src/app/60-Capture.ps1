# 采集作业：消息分发、启停、进度、导出

# ---------- UI 消息处理 ----------
# 白名单：只接受约定的命令；未知命令记日志并回传错误，绝不抛异常打断消息泵
$script:KnownCommands = @('ready', 'refreshProcs', 'saveSettings', 'openReports', 'export', 'exportHtml', 'exportPng', 'exportDiag', 'start', 'stop',
    'checkUpdate', 'downloadUpdate', 'cancelUpdate', 'openUpdatePage', 'runUpdateInstaller', 'applyUpdate', 'openUpdateFolder', 'skipUpdateVersion', 'setUpdateAuto',
    'metricsStart', 'metricsStop', 'overlayToggle', 'overlayShow', 'overlayHide')

function Handle-UiMessage($msg) {
    if ($null -eq $msg -or -not $msg.cmd) { return }
    if ($msg.cmd -notin $script:KnownCommands) {
        Write-AppLog ('未知命令已被拒绝: ' + $msg.cmd) 'WARN'
        Send-ToUi @{ type = 'error'; text = ('不支持的命令: ' + $msg.cmd) }
        return
    }
    # 检查更新的命令单独分发（宿主侧在 70-Updates.ps1，异步执行，不阻塞消息泵）
    if ($msg.cmd -in @('checkUpdate', 'downloadUpdate', 'cancelUpdate', 'openUpdatePage',
            'runUpdateInstaller', 'applyUpdate', 'openUpdateFolder', 'skipUpdateVersion', 'setUpdateAuto')) {
        try { Invoke-UpdateCommand $msg }
        catch { Write-AppLog ('更新命令执行失败: ' + $_.Exception.Message) 'WARN' }
        return
    }
    # 实时监控命令单独分发（宿主侧在 35-Metrics.ps1）
    if ($msg.cmd -in @('metricsStart', 'metricsStop')) {
        try { Invoke-MetricsCommand $msg }
        catch { Write-AppLog ('监控命令执行失败: ' + $_.Exception.Message) 'WARN' }
        return
    }
    # 浮窗命令（宿主侧在 55-Overlay.ps1）
    if ($msg.cmd -in @('overlayToggle', 'overlayShow', 'overlayHide')) {
        try { Invoke-OverlayCommand $msg }
        catch { Write-AppLog ('浮窗命令执行失败: ' + $_.Exception.Message) 'WARN' }
        return
    }
    try {
        switch ($msg.cmd) {
            'ready' {
                $procs = Get-ProcessChoices
                # 采集项清单随 init 下发；清单缺失时不下发该字段，界面自动回退内置清单
                $init = @{ type = 'init'; settings = $script:Cfg; procs = $procs }
                $opts = Get-CaptureOptions
                if ($opts) { $init.options = $opts }
                Send-ToUi $init
                # 上次退出时浮窗是开着的就恢复（位置/透明度都从配置读）
                if (Get-Command Restore-OverlayIfNeeded -ErrorAction SilentlyContinue) { Restore-OverlayIfNeeded }
                Set-TitleBarDark ($script:Cfg.theme -eq 'dark')
                Send-Log '> PerfCapture 就绪 · PresentMon ETW 零注入' 'ln-accent'
                Send-Log ('  引擎: ' + [IO.Path]::GetFileName($script:Engine))
                Send-Log ('  采集项: ' + $(if ($opts) { @($opts.options).Count.ToString() + ' 项来自 capture-options.json' } else { '内置清单（未找到 capture-options.json）' }))
                # 字体缺失回落：assets 里没有方正兰亭圆时，CSS 字体栈会退到 Microsoft YaHei UI
                $ttf = Join-Path $script:AssetDir '方正兰亭圆_GBK_中粗.ttf'
                if (Test-Path $ttf) {
                    Write-AppLog '界面字体: 方正兰亭圆（内置）'
                } else {
                    Write-AppLog '缺少 assets\方正兰亭圆_GBK_中粗.ttf，界面回落到系统字体' 'WARN'
                    Send-Log '  ! 未找到内置字体，界面已回落到系统字体（Microsoft YaHei UI）' 'ln-warn'
                }
                Send-Log '  就绪：选择目标进程后点「开始采集」'
                Write-AppLog ('UI 就绪，可用进程 ' + @($procs).Count + ' 个')
                # 启动后 12 秒自动检查一次更新（本次会话只查一次；无更新就停，下次启动恢复）
                Start-UpdateAutoCheck
            }
            'refreshProcs' {
                Send-ToUi @{ type = 'procs'; procs = (Get-ProcessChoices) }
                Send-ToUi @{ type = 'status'; text = '进程列表已刷新' }
            }
            'saveSettings' {
                if ($msg.settings) {
                    foreach ($k in 'theme', 'language', 'seconds', 'minimize', 'sound', 'skip', 'preset', 'warmup') {
                        Set-ConfigValue $k $msg.settings.$k
                    }
                    Save-Config
                    Set-TitleBarDark ($script:Cfg.theme -eq 'dark')
                }
            }
            'openReports' { Show-ReportsFolder }
            # 导出类动作不能在回调内部直接跑：SaveFileDialog 会卡住 WebView2 的消息泵，
            # 而 CDP（CallDevToolsProtocolMethodAsync）在回调里根本不会完成（实测必超时 → 界面卡在导出视图）。
            # 统一丢回消息循环执行，回调立刻返回。
            'export'      { Queue-Export @{ cmd = 'export' } }
            'exportHtml'  { Queue-Export @{ cmd = 'exportHtml'; html = [string]$msg.html } }
            'exportPng'   { Queue-Export @{ cmd = 'exportPng' } }
            'exportDiag'  { Queue-Export @{ cmd = 'exportDiag' } }
            'start'       { Start-Capture $msg }
            'stop'        { Stop-Capture }
        }
    } catch {
        Write-AppLog ('命令 {0} 执行失败: {1}' -f $msg.cmd, $_.Exception.Message) 'ERROR'
        Send-ToUi @{ type = 'error'; text = ('命令执行失败: ' + $_.Exception.Message) }
    }
}

# ---------- 导出任务排队 ----------
# WebMessageReceived 回调里不能直接弹对话框 / 调 CDP：回调不返回，WebView2 的
# 完成通知就不会派发（实测 CDP 必超时）。这里把动作排到 UI 消息循环里，回调立即返回。
$script:PendingExport = $null

function Invoke-PendingExport {
    $job = $script:PendingExport
    $script:PendingExport = $null
    if (-not $job) { return }
    switch ($job.cmd) {
        'export'     { Export-Report }
        'exportHtml' { Export-Report ([string]$job.html) }
        'exportPng'  { Export-ReportPng }
        'exportDiag' { Export-DiagBundle }
    }
}

# ---------- 诊断包（复现包） ----------
# 排查「我这崩了」时最缺的是现场：日志 + 环境快照。
# 只取日志与配置，不碰报告正文、不碰任何凭据；保存位置由用户自己选。
function Export-DiagBundle {
    # -Path 给定时直接写到该路径（探针/排障用），否则弹保存对话框由用户选位置。
    param([string]$Path)
    $target = $Path
    if (-not $target) {
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Title = '保存诊断包'
        $dlg.Filter = 'ZIP 压缩包 (*.zip)|*.zip'
        $dlg.FileName = ('PerfCapture-diag-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $target = $dlg.FileName
    }
    if (-not $target) { return }
    $stage = Join-Path $script:TempDir ('diag_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        # 1) 环境快照
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('PerfCapture 诊断包 / diagnostic bundle')
        [void]$sb.AppendLine('生成时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        [void]$sb.AppendLine('应用版本: ' + $script:AppVersion)
        [void]$sb.AppendLine('Windows : ' + [System.Environment]::OSVersion.VersionString)
        [void]$sb.AppendLine('PowerShell: ' + $PSVersionTable.PSVersion.ToString())
        [void]$sb.AppendLine('管理员权限: ' + [bool]$isAdmin)
        [void]$sb.AppendLine('WebView2 : ' + $(if ($script:WV2Version) { $script:WV2Version } else { '未知' }))
        try {
            $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
            if ($cpu) { [void]$sb.AppendLine('CPU: ' + $cpu.Name + ' / ' + $cpu.NumberOfCores + 'C' + $cpu.NumberOfLogicalProcessors + 'T / ' + $cpu.MaxClockSpeed + ' MHz') }
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            if ($os) { [void]$sb.AppendLine('内存: ' + [math]::Round($os.TotalVisibleMemorySize / 1MB, 1) + ' GB') }
        } catch { }
        $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
        if (Test-Path -LiteralPath $smi) {
            try {
                $g = & $smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>$null | Select-Object -First 1
                if ($g) { [void]$sb.AppendLine('GPU: ' + ([string]$g).Trim()) }
            } catch { }
        }
        [void]$sb.AppendLine('日志目录: ' + $script:LogDir)
        [void]$sb.AppendLine('数据目录: ' + $script:DataDir)
        [void]$sb.AppendLine('设置摘要: seconds=' + $script:Cfg.seconds + ' preset=' + $script:Cfg.preset + ' warmup=' + $script:Cfg.warmup + ' skip=' + $script:Cfg.skip + ' theme=' + $script:Cfg.theme + ' lang=' + $script:Cfg.language)
        [IO.File]::WriteAllText((Join-Path $stage 'environment.txt'), $sb.ToString(), (New-Object Text.UTF8Encoding($true)))

        # 2) 最近两天的日志
        if (Test-Path $script:LogDir) {
            Get-ChildItem $script:LogDir -Filter 'app-*.log' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 2 | ForEach-Object {
                    Copy-Item $_.FullName (Join-Path $stage $_.Name) -ErrorAction SilentlyContinue
                }
        }
        # 3) 设置文件（不含任何密钥：本应用没有密钥）
        if (Test-Path $script:CfgPath) { Copy-Item $script:CfgPath (Join-Path $stage 'PerfCapture.settings.json') -ErrorAction SilentlyContinue }

        if (Test-Path $target) { Remove-Item $target -Force -ErrorAction SilentlyContinue }
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $target -CompressionLevel Optimal
        Write-AppLog ('诊断包已导出: ' + $target)
        Send-Log ('> 诊断包已保存: ' + $target) 'ln-accent'
        Send-ToUi @{ type = 'status'; text = '诊断包已保存' }
    } catch {
        Write-AppLog ('诊断包导出失败: ' + $_.Exception.Message) 'ERROR'
        Send-ToUi @{ type = 'error'; text = ('诊断包导出失败: ' + $_.Exception.Message) }
    } finally {
        if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Queue-Export($job) {
    $script:PendingExport = $job
    if ($form) {
        [void]$form.BeginInvoke([Action]{ Invoke-PendingExport })
    } else {
        Invoke-PendingExport
    }
}

function Stop-Capture {
    if ($script:Job) {
        try { Stop-Job $script:Job -ErrorAction SilentlyContinue } catch { }
        try { Remove-Job $script:Job -Force -ErrorAction SilentlyContinue } catch { }
        $script:Job = $null
    }
    $script:Timer.Stop()
    Send-ToUi @{ type = 'busy'; value = $false }
    Send-ToUi @{ type = 'status'; text = '已中止采集' }
    Send-Log '已中止采集' 'ln-warn'
}

function Start-Capture($msg) {
    if ($script:Job) { return }
    if (-not (Test-Path $script:Engine)) {
        Send-ToUi @{ type = 'error'; text = '找不到采集引擎 Measure-GamePerf.ps1' }
        return
    }
    $sec = [int]$msg.seconds
    $pid0 = [int]$msg.pid
    $pname = ''
    foreach ($p in (Get-ProcessChoices)) { if ($p.pid -eq $pid0) { $pname = $p.name; break } }
    if (-not $pname) { $pname = 'game.exe' }

    $skip = [string]$msg.skip
    # 预热丢弃：界面按预设给的秒数，越界一律夹到 0–30（引擎侧还会再校验一次）
    $warmup = 0
    if ($null -ne $msg.warmup) { $warmup = [int]$msg.warmup }
    if ($warmup -lt 0) { $warmup = 0 }
    if ($warmup -gt 30) { $warmup = 30 }
    if ($warmup -ge $sec - 10) { $warmup = [math]::Max(0, $sec - 10) }   # 别把整段采集都丢光
    $theme = [string]$msg.theme
    if ($theme -eq 'system') {
        $light = $true
        try {
            $light = ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 1)
        } catch { }
        $theme = if ($light) { 'light' } else { 'dark' }
    }
    $cd = if ($msg.minimize) { 5 } else { 0 }

    # PresentMon 的 ETW 会话是全局互斥的：采集开始时必须停掉实时监控的增量 PresentMon，
    # 否则引擎会先杀进程再抢会话，实时值变成一串假的 0。停掉后回到实时页会重新启动。
    if ($script:MetricsRunning) {
        try { Stop-MetricsSampler } catch { }
        Write-AppLog '开始采集：已暂停实时监控（PresentMon 会话互斥）'
    }

    $script:Cfg.lastPid = $pid0
    $script:Cfg.seconds = $sec
    Save-Config

    $script:Before = @(Get-ChildItem $script:OutDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $script:TotalSec = $cd + $sec
    $script:LogIdx = 0
    if (Test-Path $script:TempHtml) { Remove-Item $script:TempHtml -Force -ErrorAction SilentlyContinue }

    Send-ToUi @{ type = 'busy'; value = $true }
    Send-ToUi @{ type = 'progress'; pct = 0 }
    Send-ToUi @{ type = 'status'; text = ('准备采集 ' + $pname + '，共 ' + $sec + ' 秒') }

    if ($msg.minimize) { $form.WindowState = 'Minimized' }

    $script:T0 = Get-Date
    $script:Job = Start-Job -ArgumentList $script:Engine, $sec, $pid0, $pname, $script:OutDir, $cd, $skip, $theme, $script:TempHtml, $warmup -ScriptBlock {
        param($eng, $s, $targetPid, $pname, $out, $cd, $skip, $theme, $html, $warmup)
        & $eng -Seconds $s -ProcessId $targetPid -ProcessName $pname -Label 'run' -OutDir $out `
              -Countdown $cd -NoPause -Skip $skip -Theme $theme -HtmlPath $html -WarmupSec $warmup *>&1
    }
    $script:Timer.Start()
}

# ---------- 采集推进 ----------
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 400
$script:Timer.Add_Tick({
    if (-not $script:Job) { return }

    # 转发引擎输出（增量）
    try {
        $out = @(Receive-Job $script:Job -Keep -ErrorAction SilentlyContinue)
        if ($out.Count -gt $script:LogIdx) {
            for ($i = $script:LogIdx; $i -lt $out.Count; $i++) {
                $line = [string]$out[$i]
                if ($line.Trim() -eq '') { continue }
                $cls = ''
                if ($line -match '失败|错误|ERROR|Error|Warning') { $cls = 'ln-warn' }
                elseif ($line -match '^=+|^----') { $cls = 'ln-accent' }
                Send-Log $line $cls
            }
            $script:LogIdx = $out.Count
        }
    } catch { }

    $elapsed = [int]((Get-Date) - $script:T0).TotalSeconds
    $remain = [math]::Max(0, $script:TotalSec - $elapsed)
    $pct = 0
    if ($script:TotalSec -gt 0) { $pct = [int](100 * $elapsed / $script:TotalSec) }
    Send-ToUi @{ type = 'progress'; pct = $pct }
    Send-ToUi @{ type = 'status'; text = ('采集中：已用 ' + $elapsed + ' 秒，剩余 ' + $remain + ' 秒') }

    if ($script:Job.State -ne 'Running') {
        $script:Timer.Stop()
        if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal'; $form.Activate() }
        Send-ToUi @{ type = 'progress'; pct = 100 }

        try { Receive-Job $script:Job -ErrorAction SilentlyContinue | ForEach-Object { if ($_ -ne '') { Send-Log ([string]$_) } } } catch { }
        try { Remove-Job $script:Job -Force -ErrorAction SilentlyContinue } catch { }
        $script:Job = $null

        if ($script:Cfg.sound) { try { [System.Media.SystemSounds]::Asterisk.Play() } catch { } }

        $newFile = Get-ChildItem $script:OutDir -Filter '*.json' -ErrorAction SilentlyContinue |
                   Where-Object { $script:Before -notcontains $_.Name } |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $newFile) {
            Send-ToUi @{ type = 'status'; text = '采集失败：没有生成结果' }
            Send-Log '失败: 采集没有生成结果文件' 'ln-warn'
        } else {
            $data = $null
            try { $data = Get-Content $newFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
            if ($null -eq $data) {
                Send-ToUi @{ type = 'status'; text = '采集完成，但结果文件解析失败' }
                Send-Log ('失败: 无法解析 ' + $newFile.Name) 'ln-warn'
            } else {
                $script:LastJson = $newFile.FullName
                $script:LastRun = [string]$data.run
                Send-ToUi @{ type = 'report'; data = $data }
                Send-ToUi @{ type = 'exportable'; value = $true }
                Send-ToUi @{ type = 'status'; text = '采集完成' }
                Send-Log ''
                Send-Log ('  平均帧率  ' + $data.avg_fps)
                if ($null -ne $data.display_latency_avg_ms) { Send-Log ('  上屏延迟  ' + $data.display_latency_avg_ms + ' ms') }
                if ($null -ne $data.pc_latency_avg_ms) { Send-Log ('  PC 延迟   ' + $data.pc_latency_avg_ms + ' ms') }
                Send-Log '  报告已显示在右侧，需要文件请点「导出报告」' 'ln-accent'
            }
        }
        Send-ToUi @{ type = 'busy'; value = $false }
    }
})

# ---------- 导出 ----------
function Export-Report {
    param([string]$Html = '')
    if (-not $script:LastJson) {
        Send-ToUi @{ type = 'status'; text = '还没有可导出的报告' }
        return
    }
    $src = $script:TempHtml
    if (-not (Test-Path $src)) {
        $cand = Join-Path $script:OutDir ($script:LastRun + '.html')
        if (Test-Path $cand) { $src = $cand }
    }
    # 有前端传来的 HTML 就用它（跟随当前语言与主题）；否则回退到引擎生成的 HTML
    if (-not $Html -and -not (Test-Path $src)) {
        Send-ToUi @{ type = 'error'; text = '找不到报告文件，请重新采集一次' }
        return
    }
    $name = $script:LastRun
    if (-not $name) { $name = 'PerfCapture-report' }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = '导出性能报告'
    $dlg.Filter = 'HTML 报告 (*.html)|*.html'
    $dlg.InitialDirectory = $script:OutDir
    $dlg.FileName = $name + '.html'
    $dlg.OverwritePrompt = $true
    $dlg.AddExtension = $true
    if ($dlg.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        if ($Html) {
            [System.IO.File]::WriteAllText($dlg.FileName, $Html, (New-Object System.Text.UTF8Encoding($true)))
        } else {
            Copy-Item -LiteralPath $src -Destination $dlg.FileName -Force
        }
        Send-Log ('> 已导出: ' + $dlg.FileName) 'ln-accent'
        Send-ToUi @{ type = 'status'; text = '报告已导出：' + [IO.Path]::GetFileName($dlg.FileName) }
        Start-Process $dlg.FileName
    } catch {
        Send-ToUi @{ type = 'error'; text = ('导出失败：' + $_.Exception.Message) }
    }
}

# ---------- 导出长图 ----------
# 截图 clip 计算：Chromium 单张纹理上限约 16384px，超出就降 scale
# （scale < 1 表示整图缩小，宁可稍微糊一点也不丢内容）
function Get-PngClip([double]$w, [double]$h) {
    $limit = 16384
    $w = [math]::Max(1, $w)
    $h = [math]::Max(1, $h)
    $scale = [math]::Min(2.0, [math]::Min($limit / $w, $limit / $h))
    @{
        x      = 0
        y      = 0
        width  = [math]::Round($w, 0)
        height = [math]::Round($h, 0)
        scale  = [math]::Round($scale, 3)
    }
}

# ---------- 导出提示窗 ----------
# 导出期间主窗口会被设成全透明（见下面的说明），用户看不到任何动静会以为程序挂了，
# 所以给一个居中的小提示窗：细边框无标题栏 + 跑马灯进度条，2~3 秒后自动关掉。
$script:ExportToast = $null
$script:ToastFont = $null

function Get-ToastFont([double]$Size) {
    if (-not $script:ToastFont) {
        try {
            $ttf = Join-Path $script:AssetDir '方正兰亭圆_GBK_中粗.ttf'
            if (Test-Path $ttf) {
                $fc = New-Object System.Drawing.Text.PrivateFontCollection
                $fc.AddFontFile($ttf)
                $script:ToastFont = $fc.Families[0]
            }
        } catch { }
    }
    if ($script:ToastFont) { return (New-Object System.Drawing.Font($script:ToastFont, [single]$Size, [System.Drawing.FontStyle]::Regular)) }
    return (New-Object System.Drawing.Font('Microsoft YaHei UI', [single]$Size, [System.Drawing.FontStyle]::Regular))
}

function Get-ToastText {
    switch ([string]$script:Cfg.language) {
        'en-US' { return @{ Title = 'Exporting report image…'; Hint = 'This takes a few seconds' } }
        'ja-JP' { return @{ Title = 'レポート画像を書き出しています…'; Hint = '数秒かかります' } }
        default { return @{ Title = '正在导出报告长图…'; Hint = '抓取整页画面，需要几秒' } }
    }
}

function Show-ExportToast {
    if ($script:ExportToast) { return }
    $dark = ($script:Cfg.theme -eq 'dark')
    if ($script:Cfg.theme -eq 'system') {
        try { $dark = ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -ne 1) } catch { }
    }
    $txt = Get-ToastText
    $w = [int](360 * $script:DpiScale)
    $h = [int](112 * $script:DpiScale)
    $t = New-Object System.Windows.Forms.Form
    # 关掉 WinForms 自己的字体缩放：DPI 由进程感知 + 下面的 DpiScale 手工算过一次，
    # 再让 AutoScale 一次会把字号放大 1.5 倍（文字溢出标签，看起来发糊）。
    $t.AutoScaleMode = 'None'
    $t.Text = $txt.Title
    $t.FormBorderStyle = 'FixedSingle'
    $t.ControlBox = $false
    $t.ShowInTaskbar = $false
    $t.TopMost = $true
    $t.StartPosition = 'CenterScreen'
    $t.ClientSize = New-Object System.Drawing.Size($w, $h)
    $t.BackColor = if ($dark) { [System.Drawing.Color]::FromArgb(22, 27, 34) } else { [System.Drawing.Color]::FromArgb(255, 255, 255) }
    $t.ForeColor = if ($dark) { [System.Drawing.Color]::FromArgb(240, 246, 252) } else { [System.Drawing.Color]::FromArgb(38, 35, 48) }

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.AutoSize = $false
    $lbl.TextAlign = 'MiddleCenter'
    $lbl.UseCompatibleTextRendering = $false   # GDI 渲染，ClearType 更锐利
    $lbl.Font = Get-ToastFont 11.5
    $lbl.ForeColor = $t.ForeColor
    $lbl.Text = $txt.Title
    $lbl.SetBounds([int](10 * $script:DpiScale), [int](16 * $script:DpiScale), $w - [int](20 * $script:DpiScale), [int](28 * $script:DpiScale))
    $t.Controls.Add($lbl)

    $sub = New-Object System.Windows.Forms.Label
    $sub.AutoSize = $false
    $sub.TextAlign = 'MiddleCenter'
    $sub.UseCompatibleTextRendering = $false
    $sub.Font = Get-ToastFont 9
    $sub.ForeColor = if ($dark) { [System.Drawing.Color]::FromArgb(139, 148, 158) } else { [System.Drawing.Color]::FromArgb(102, 98, 120) }
    $sub.Text = $txt.Hint
    $sub.SetBounds([int](10 * $script:DpiScale), [int](44 * $script:DpiScale), $w - [int](20 * $script:DpiScale), [int](20 * $script:DpiScale))
    $t.Controls.Add($sub)

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Style = 'Marquee'
    $bar.MarqueeAnimationSpeed = 30
    $bar.SetBounds([int](16 * $script:DpiScale), [int](72 * $script:DpiScale), $w - [int](32 * $script:DpiScale), [int](10 * $script:DpiScale))
    $t.Controls.Add($bar)

    $script:ExportToast = $t
    try { $t.Show() } catch { $script:ExportToast = $null }
    [System.Windows.Forms.Application]::DoEvents()
}

function Hide-ExportToast {
    if (-not $script:ExportToast) { return }
    try { $script:ExportToast.Close() } catch { }
    try { $script:ExportToast.Dispose() } catch { }
    $script:ExportToast = $null
    [System.Windows.Forms.Application]::DoEvents()
}

# 导出长图。**先弹保存对话框，再切导出视图，整个过程窗口完全看不见**：
#   旧顺序是「切视图 → 截图（几秒）→ 才弹框」，用户看到的是窗口先被放大成整页、
#   等半天才出现选择路径的对话框（1.7.1 反馈）；
#   1.8.0 改成先弹框，但选完路径仍会看到版面被撑开一下（1.8.0 反馈）。
# **不能用 $form.Hide()、也不能 SW_HIDE**：主界面是 $form.ShowDialog() 模态循环，
#   它的循环条件是"窗口仍可见"，Visible=false 会让循环直接结束 —— 程序会自己关掉
#   （1.8.1 实测事故）。也**不能最小化**：实测 CallDevToolsProtocolMethodAsync 会挂住。
# 唯一安全且真正看不见的做法是 **Opacity = 0**：窗口一直 Visible（主循环不受影响）、
#   不动 WindowState（最大化也不会被还原），CDP 截图与可见时完全一致（实测字节数相同、
#   不透明 100%）。结束时把 Opacity 设回 1 即可，不抢焦点、不置顶。
# 无论成功、失败还是用户取消，最后都要回 pngDone，否则界面会一直停在导出视图。

function Export-ReportPng {
    $ok = $false
    try {
    $hidden = $false
        if (-not $script:LastJson) { throw '还没有可导出的报告' }
        if (-not (Test-Path $script:OutDir)) { New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null }

        $name = if ($script:LastRun) { $script:LastRun } else { 'PerfCapture-report' }
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Title = '导出报告长图'
        $dlg.Filter = 'PNG 图片 (*.png)|*.png'
        $dlg.InitialDirectory = $script:OutDir
        $dlg.FileName = $name + '.png'
        $dlg.OverwritePrompt = $true
        $dlg.AddExtension = $true
        # 用户取消就到此为止：不进导出视图，界面一个像素都不动
        if ($dlg.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        # 先亮出"正在导出"的提示窗（主窗口马上要变全透明，不给反馈会让人以为程序挂了），
        # 再把主窗口设为全透明并切视图：版面会被撑成整页，看得见就像"窗口突然被放大"。
        # 注意是 Opacity 不是 Hide —— Hide/最小化都会把主循环或 CDP 搞死（见上面的注释）。
        Show-ExportToast
        try { $form.Opacity = 0; $hidden = $true } catch { }
        [System.Windows.Forms.Application]::DoEvents()
        # 切到导出视图（整页展开 + 图表按 2 倍栅格重画），再泵消息等布局与重绘落地
        if ((Invoke-UiScript 'setExportView(true)') -notmatch 'true') { throw '界面没有进入导出视图' }
        $settle = [System.Diagnostics.Stopwatch]::StartNew()
        while ($settle.ElapsedMilliseconds -lt 300) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 20
        }

        $metrics = (Invoke-DevTools 'Page.getLayoutMetrics' '{}') | ConvertFrom-Json
        $size = $metrics.cssContentSize
        if (-not $size) { $size = $metrics.contentSize }
        if (-not $size) { throw '拿不到页面尺寸' }

        $clip = Get-PngClip ([double]$size.width) ([double]$size.height)
        if ($clip.scale -lt 1) {
            Write-AppLog ('报告超高，长图按 ' + $clip.scale + ' 倍缩小以避开 16384px 上限') 'WARN'
        }

        $params = @{
            format                = 'png'
            fromSurface           = $true
            captureBeyondViewport = $true
            clip                  = $clip
        } | ConvertTo-Json -Depth 5 -Compress

        $shot = (Invoke-DevTools 'Page.captureScreenshot' $params 30000) | ConvertFrom-Json
        if (-not $shot.data) { throw '截图没有返回图像数据' }
        $bytes = [Convert]::FromBase64String($shot.data)

        [System.IO.File]::WriteAllBytes($dlg.FileName, $bytes)
        $ok = $true
        Send-Log ('> 已导出长图: ' + $dlg.FileName + '  (' + [math]::Round($bytes.Length / 1KB) + ' KB, ' + $clip.width + '×' + $clip.height + ' @' + $clip.scale + 'x)') 'ln-accent'
        Send-ToUi @{ type = 'status'; text = '长图已导出：' + [IO.Path]::GetFileName($dlg.FileName) }
        Start-Process $dlg.FileName
    } catch {
        Write-AppLog ('导出长图失败: ' + $_.Exception.Message) 'ERROR'
        Send-Log ('导出长图失败: ' + $_.Exception.Message) 'ln-warn'
        Send-ToUi @{ type = 'error'; text = ('导出长图失败：' + $_.Exception.Message) }
    } finally {
        # 提示窗最先关（否则会盖在还原后的界面上）；再还原视图 → 恢复不透明度 → 兜底可见性。
        # 顺序很重要：还原视图在"全透明"状态下完成，用户就看不到版面被撑开的那一瞬。
        Hide-ExportToast
        if ($script:Core) {
            try { [void](Invoke-UiScript 'setExportView(false)') } catch { }
        }
        if ($hidden) {
            $hidden = $false
            try { $form.Opacity = 1; [System.Windows.Forms.Application]::DoEvents() } catch { }
        }
        # 兜底：无论上面出了什么岔子，窗口都必须还在。主界面是 ShowDialog 模态窗口，
        # 一旦变成不可见，模态循环会直接结束 —— 也就是用户看到的"程序自己关掉了"。
        try { if (-not $form.Visible) { $form.Show() } } catch { }
        Send-ToUi @{ type = 'pngDone'; ok = $ok }
    }
}
