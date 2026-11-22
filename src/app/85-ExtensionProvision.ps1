# 扩展供应层（批次 E / E1 止血 / E2 下载体验 / E3 安装确认）：软件内下载 / 校验 / 静默安装 / 配置 / 启动 / 回滚。
# 边界：这里只处理「由扩展中心自己下载并托管的副本」。用户机器上预先存在的 RTSS 一律无视，
#       不探测、不复用、不结束；本机自有副本的路径与 PID 全部来自持久化状态。
# 设计：注册表 extensions.json 的 package 字段是唯一配置源；本文件不含版本、URL、路径、哈希常量。
#       UI 线程只负责发命令与轮询，耗时动作在 runspace 里跑，进度经线程安全队列回推。
# E1 止血（2.1.2）：空参数不进 Start-Process；配置前置自检；阶段化异常带原因与详情；
#       UAC 取消单独映射；通过 SHA-256 的归档保留为缓存，回滚只删临时产物。
# E2 下载体验（2.1.7）：流式下载回推百分比 / 速度 / 剩余时间；.part + Range 断点续传；
#       多源回退（url + urls）；连接超时与总超时分离；maxBytes 全程检查；用户可取消。
# E3 安装确认（2.1.7）：安装器类型自适应（nsis / inno / msi / script）；配置写后回读校验；
#       共享内存未就绪细分（进程 / 对象 / 帧数据三项事实）；失败写诊断包到 %LOCALAPPDATA%\PerfCapture\logs。
#       每个阶段都包在 try/catch 里：失败即回滚，绝不写 installed/enabled，绝不切换数据源。

# ---------- 脚本级状态 ----------
$script:ExtProvCtx      = $null
$script:ExtProvTimer    = $null
$script:ExtProvQueue    = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
# 取消信号：跨 runspace 共享同一个 hashtable（引用传递），worker 每个阶段边界与下载循环里检查。
# 用 hashtable 而不是 CancellationTokenSource：后者跨 runspace 传递后 Dispose 时机很难收敛。
$script:ExtProvCancel   = @{ requested = $false }

# ---------- 模板展开：所有路径/参数都来自注册表，不用硬编码 ----------
function Expand-ExtensionTemplate {
    param([string]$Text, [hashtable]$Tokens)
    if (-not $Text) { return '' }
    $out = [string]$Text
    foreach ($k in $Tokens.Keys) {
        $out = [regex]::Replace($out, '\{' + [regex]::Escape($k) + '\}', [string]$Tokens[$k], 'IgnoreCase')
    }
    return $out
}

# ---------- runspace 内执行的供应worker ----------
# 刻意只用 .NET 与内置 cmdlet，不依赖 UI 主线程状态；失败一律回滚后返回结构化结果。
$script:ExtensionProvisionWorker = @'
param([hashtable]$Spec, [System.Collections.Concurrent.ConcurrentQueue[object]]$ProgressQueue, [string]$RtssReaderCode, [string]$NetProxyHelper)
if ($NetProxyHelper) { . ([scriptblock]::Create($NetProxyHelper)) }
# M1：网络请求显式走系统代理；诊断与日志统一记 proxy=<...>，失败时再直连一次。
$proxyInfo = Get-NetProxyDescriptor ([string]$Spec.url)
$directInfo = Get-DirectProxyInfo

# 运行态校验复用宿主那份读取器（唯一实现，避免两处维护同一套结构常量）。
# 宿主在启动 worker 时把读取器源码作为参数传进来，这里点源到当前 runspace。
if ($RtssReaderCode -and -not (Get-Command Get-RtssFrameSnapshot -ErrorAction SilentlyContinue)) {
    . ([scriptblock]::Create($RtssReaderCode))
}

# runspace 自带一份模板展开，不依赖宿主页作用域。
function Expand-Tmpl([string]$Text, [hashtable]$Tokens) {
    if (-not $Text) { return '' }
    $out = [string]$Text
    foreach ($k in $Tokens.Keys) {
        $out = [regex]::Replace($out, '\{' + [regex]::Escape($k) + '\}', [string]$Tokens[$k], 'IgnoreCase')
    }
    return $out
}

# ---------- 进度 / 时间线 / 取消 ----------

# extra：附加字段（下载用 recv/total/bps/eta），前端据此显示真实速度与剩余时间；
# 阶段通用字段（stage/pct/detail）保持不变，老前端只读这三个也不会坏。
function Emit([string]$stage, [int]$pct, [string]$detail = '', [hashtable]$extra = $null) {
    $msg = @{ type = 'extensionProgress'; id = $Spec.id; stage = $stage; pct = $pct; detail = $detail }
    if ($extra) { foreach ($k in $extra.Keys) { $msg[[string]$k] = $extra[$k] } }
    $ProgressQueue.Enqueue($msg)
    try {
        $line = (Get-Date).ToString('HH:mm:ss.fff') + ' | ' + $stage + ' | ' + $pct + '%'
        if ($detail) { $line += ' | ' + $detail }
        $timeline.Add($line)
    } catch { }
}

function Test-ProvisionCancel {
    if ($Spec.cancelSignal -and [bool]$Spec.cancelSignal.requested) { return $true }
    return $false
}

# 取消不是故障：用固定哨兵串抛出，由 Fail-Stage 统一映射成 cancelled。
function Assert-NotCancelled {
    if (Test-ProvisionCancel) { throw 'cancelled' }
}

# 失败即写诊断包：阶段时间线 + 各源状态 + 哈希比对 + 安装器退出码 + 运行时事实。
# 只写 %LOCALAPPDATA%\PerfCapture\logs，不往外发、不跳网页；UI 的「复制诊断信息」直接复制 detail。
function Save-ProvisionDiagnostics([string]$Reason, [string]$Detail) {
    try {
        if (-not $Spec.diagDir) { return '' }
        if (-not (Test-Path -LiteralPath $Spec.diagDir)) {
            New-Item -ItemType Directory -Path $Spec.diagDir -Force | Out-Null
        }
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $file = [System.IO.Path]::Combine([string]$Spec.diagDir, ('diagnostics-' + [string]$Spec.id + '-' + $stamp + '.txt'))
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('PerfCapture 扩展供应诊断包')
        $lines.Add('扩展: ' + [string]$Spec.id + ' / 包版本: ' + [string]$Spec.version + ' / 模式: ' + [string]$Spec.mode)
        $lines.Add('时间: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
        $lines.Add('结果: ' + $Reason)
        $lines.Add('详情: ' + $Detail)
        $lines.Add('网络: proxy=' + $proxyInfo.label + '（来源: ' + $proxyInfo.source + '）')
        $lines.Add('')
        $lines.Add('-- 阶段时间线 --')
        foreach ($t in $timeline) { $lines.Add($t) }
        $lines.Add('')
        $lines.Add('-- 下载源（查询串已剥离） --')
        if ($sourceLog.Count -eq 0) { $lines.Add('（未进入下载阶段）') }
        foreach ($s in $sourceLog) { $lines.Add($s) }
        $lines.Add('')
        $lines.Add('-- 校验 --')
        $lines.Add('期望 SHA-256: ' + [string]$Spec.sha256)
        $lines.Add('实际 SHA-256: ' + $(if ($actualSha) { $actualSha } else { '（未计算）' }))
        $lines.Add('安装器类型: ' + [string]$Spec.installerKind + ' / 提权: ' + [string]$Spec.elevateInstall)
        $lines.Add('安装器: ' + [string]$diagFacts['installer'])
        $lines.Add('安装器退出码: ' + [string]$diagFacts['installerExit'])
        $lines.Add('运行时事实: ' + [string]$diagFacts['runtime'])
        $lines.Add('')
        $lines.Add('-- 目标与缓存 --')
        $lines.Add('目标目录: ' + [string]$Spec.targetDir + '（已存在=' + [string](Test-Path -LiteralPath ([string]$Spec.targetDir)) + '）')
        $lines.Add('缓存目录: ' + [string]$Spec.cacheDir)
        $lines.Add('归档: ' + [string]$archivePath + '（存在=' + [string](Test-Path -LiteralPath ([string]$archivePath)) + '）')
        $lines.Add('')
        $lines.Add('-- 环境 --')
        $lines.Add('PowerShell: ' + $PSVersionTable.PSVersion.ToString())
        $lines.Add('OS: ' + [System.Environment]::OSVersion.VersionString)
        $lines.Add('64 位进程: ' + [string][System.Environment]::Is64BitProcess)

        $enc = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllLines($file, $lines.ToArray(), $enc)
        return $file
    } catch { return '' }
}

# 失败收口：rolledBack=true 时由这里**真正执行**回滚，调用点只声明意图。
# 为什么放在这里：E1 之前有若干分支只是把 rolledBack 标成 true 却没回滚，
# 结果「报了已回滚、目标目录其实还在」。回滚只有一条路径才不会再漏。
function Fail-Step([string]$reason, [string]$detail, [bool]$rolledBack) {
    if ($rolledBack) { try { $null = Invoke-ProvisionRollback } catch { } }
    Emit 'failed' 0 $detail
    $diag = ''
    try { $diag = Save-ProvisionDiagnostics $reason $detail } catch { }
    if ($diag) { $detail = $detail + "`n诊断包：" + $diag }
    return [pscustomobject]@{ ok = $false; reason = $reason; detail = $detail; rolledBack = $rolledBack; diagPath = $diag }
}

# 阶段化失败：统一回滚、统一「阶段 + 原始异常」文案；reason 保留细分值，便于 UI 给出可操作提示。
function Fail-Stage([string]$Stage, [string]$Detail, [string]$Reason = '') {
    if ($Detail -eq 'cancelled' -or $Reason -eq 'cancelled') {
        # 取消按失败回滚处理，但不写 installed/enabled；文案明确「未做任何更改」，用户可立即重试。
        return Fail-Step 'cancelled' '已取消，未做任何更改' $true
    }
    $why = if ($Reason) { $Reason } else { ($Stage + 'Failed') }
    return Fail-Step $why ($Stage + ' 阶段：' + $Detail) $true
}

function Get-Sha256([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '').ToUpperInvariant() }
        finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}

# ---------- 配置文件读写（供 configure 阶段与回读校验共用） ----------
function Set-MergedEntries([string]$path, [hashtable]$entries) {
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $path) {
        foreach ($ln in [System.IO.File]::ReadAllLines($path)) { $lines.Add([string]$ln) }
    }
    foreach ($key in $entries.Keys) {
        $target = [string]$key + '=' + [string]$entries[$key]
        $hit = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match ('^\s*' + [regex]::Escape([string]$key) + '\s*=')) { $hit = $i; break }
        }
        if ($hit -ge 0) { $lines[$hit] = $target } else { $lines.Add($target) }
    }
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllLines($path, $lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
}

# 回读：把 key=value 解析成表，用于「写完必须能读回」的生效验证（E3）。
function Get-EntryMap([string]$path) {
    $map = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $map }
    foreach ($ln in [System.IO.File]::ReadAllLines($path)) {
        $m = [regex]::Match([string]$ln, '^\s*([^=]+?)\s*=\s*(.*)$')
        if ($m.Success) { $map[$m.Groups[1].Value.Trim()] = $m.Groups[2].Value.Trim() }
    }
    return $map
}

# ---------- 安装器类型自适应（E3） ----------
# 只把「怎么启动」这件差异收进一张表：msi 交给 msiexec、script 交给 powershell，
# nsis / inno 与其它 exe 安装器都是「直接跑 + 配置里的静默参数」。
# 新增一种安装器只加一行，不在下游 if/else 里写扩展专属分支。
function Get-InstallerPlan([string]$Kind, [string]$Installer, [string]$ArgLine) {
    $extra = ''
    if (-not [string]::IsNullOrWhiteSpace($ArgLine)) { $extra = ' ' + $ArgLine }
    switch (([string]$Kind).ToLowerInvariant()) {
        'msi' {
            return @{ file = 'msiexec.exe'; args = ('/i "' + $Installer + '"' + $extra); elevate = $true }
        }
        'script' {
            return @{ file = 'powershell.exe'; args = ('-NoProfile -ExecutionPolicy Bypass -File "' + $Installer + '"' + $extra); elevate = $false }
        }
        default {
            # nsis / inno / 其它可执行安装器
            return @{ file = $Installer; args = $ArgLine; elevate = $true }
        }
    }
}

# 统一进程启动器：ArgumentList 为空时**不传该参数**。
# PowerShell 5.1 对 -ArgumentList @() 或 '' 会抛「参数验证失败」，批次 E 真机故障即出于此。
# 传字符串而非数组：含空格的参数行由注册表自行用引号包裹；NSIS /D= 必须放最后且不加引号。
# Wait 显式区分：安装器要等到退出码，自有副本要长期驻留，绝不能等待。
function Start-ProvisionProcess([string]$File, [string]$ArgLine, [bool]$Elevate, [bool]$Wait) {
    $params = @{ FilePath = $File; PassThru = $true }
    if (-not [string]::IsNullOrWhiteSpace($ArgLine)) { $params.ArgumentList = $ArgLine }
    if ($Elevate) { $params.Verb = 'RunAs' }
    if ($Wait) { $params.Wait = $true }
    return Start-Process @params
}

# ---------- 下载（E2） ----------
function Get-SafeUrl([string]$Url) {
    if (-not $Url) { return '' }
    $i = $Url.IndexOf('?')
    if ($i -ge 0) { return $Url.Substring(0, $i) }
    return $Url
}

# 源清单：url 是首选，urls 是配置化备用镜像。同一地址只试一次，顺序即默认优先级。
function Get-ProvisionSources {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($u in (@($Spec.url) + @($Spec.urls))) {
        $s = [string]$u
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if (-not $out.Contains($s)) { $out.Add($s) }
    }
    return $out.ToArray()
}

# 探测排序（2.1.8）：并发向每个源发 `Range: bytes=0-0`，按首字节耗时排序。
# 为什么要有这一步：跨境源「连不上 / 连得上但握手慢」时，用完整下载去逐个试要付出
# 连接超时（8s）× N 的代价，用户看到的就是「转圈很久然后失败」。探测把这段压到一次 6 秒。
# 全部失败的源保留在队尾：主源下到一半断了，仍可退回去试（此时它可能已经恢复）。
# 返回 @{ order = 排好序的源; facts = 诊断事实 }。
function Select-ProvisionSources([string[]]$Sources) {
    $list = @($Sources | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $facts = New-Object System.Collections.Generic.List[string]
    if ($list.Count -le 1) {
        if ($list.Count -eq 1) { $facts.Add('probe ' + (Get-SafeUrl $list[0]) + ' -> skipped(only)') }
        return @{ order = $list; facts = $facts }
    }
    $probeMs = [int]$Spec.probeTimeoutMs
    if ($probeMs -lt 1000) { $probeMs = 6000 }
    $client = $null
    $cts = $null
    $jobs = @()
    try {
        try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { return @{ order = $list; facts = $facts } }
        $client = New-ProxyHttpClient $proxyInfo ($probeMs + 2000)
        try { $client.DefaultRequestHeaders.UserAgent.ParseAdd('PerfCapture') } catch { }
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter($probeMs)
        foreach ($s in $list) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $task = $null
            try {
                $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $s)
                $req.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue(0, 0)
                $task = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token)
            } catch { }
            $jobs += [pscustomobject]@{ Url = [string]$s; Task = $task; Sw = $sw; Ms = -1; Ok = $false }
        }
        $tasks = @($jobs | Where-Object { $_.Task } | ForEach-Object { $_.Task })
        if ($tasks.Count) { try { [void][System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]$tasks, $probeMs) } catch { } }
        foreach ($j in $jobs) {
            if (-not $j.Task) { continue }
            try {
                if ($j.Task.IsCompleted) {
                    $resp = $j.Task.GetAwaiter().GetResult()
                    if ($resp -and $resp.IsSuccessStatusCode) {
                        $j.Ok = $true
                        $j.Ms = [int]$j.Sw.ElapsedMilliseconds
                    }
                    try { $resp.Dispose() } catch { }
                }
            } catch { }
            try { $j.Sw.Stop() } catch { }
            $facts.Add('probe ' + (Get-SafeUrl $j.Url) + ' -> ' + $(if ($j.Ok) { ([string]$j.Ms + 'ms') } else { 'unreachable' }))
        }
    } catch {
        $facts.Add('probe -> ' + $_.Exception.Message)
    } finally {
        try { if ($cts) { $cts.Dispose() } } catch { }
        try { if ($client) { $client.Dispose() } } catch { }
    }
    $okList = @($jobs | Where-Object { $_.Ok } | Sort-Object -Property Ms | ForEach-Object { $_.Url })
    # M1 直连回退：代理下所有源都探不通时，再直连探一次；失败也只多花一轮探测预算。
    if (-not $okList.Count -and $proxyInfo.active) {
        $facts.Add('proxy unreachable -> retry probe direct')
        $dclient = $null; $dcts = $null
        try {
            $dclient = New-ProxyHttpClient $directInfo ($probeMs + 2000)
            $dcts = New-Object System.Threading.CancellationTokenSource
            $dcts.CancelAfter($probeMs)
            foreach ($j in $jobs) {
                $t = $null
                try {
                    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $j.Url)
                    $req.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue(0, 0)
                    $t = $dclient.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $dcts.Token)
                    if ($t.IsCompleted) {
                        $resp = $t.GetAwaiter().GetResult()
                        if ($resp -and $resp.IsSuccessStatusCode) { $j.Ok = $true; $j.Ms = [int]$j.Sw.ElapsedMilliseconds }
                        try { if ($resp) { $resp.Dispose() } } catch { }
                    }
                } catch { }
                $facts.Add('direct ' + (Get-SafeUrl $j.Url) + ' -> ' + $(if ($j.Ok) { ([string]$j.Ms + 'ms') } else { 'unreachable' }))
            }
            $okList = @($jobs | Where-Object { $_.Ok } | Sort-Object -Property Ms | ForEach-Object { $_.Url })
        } catch { } finally {
            try { if ($dcts) { $dcts.Dispose() } } catch { }
            try { if ($dclient) { $dclient.Dispose() } } catch { }
        }
    }
    $badList = @($jobs | Where-Object { -not $_.Ok } | ForEach-Object { $_.Url })
    # 一个都没探通，不要直接判死：保持原顺序交给下载去试（探测本身也可能被中间设备拦掉）。
    if (-not $okList.Count) { return @{ order = $list; facts = $facts } }
    return @{ order = @($okList + $badList); facts = $facts }
}

function Send-DownloadProgress([int64]$Recv, [int64]$Total, [double]$Seconds) {
    # part = 本次下载的完成度（0–100，未知总长时 -1）；pct = 整体进度（下载占 12%–30%）。
    # 前端用 part 显示「正在下载 85%」，用 pct 画进度条，两者都不失真。
    $part = -1
    if ($Total -gt 0) {
        $ratio = [double]$Recv / [double]$Total
        if ($ratio -gt 1) { $ratio = 1 }
        if ($ratio -lt 0) { $ratio = 0 }
        $part = [int][math]::Round($ratio * 100)
    }
    $pct = if ($part -ge 0) { 12 + [int][math]::Round($part * 18 / 100) } else { 12 }
    $bps = 0
    if ($Seconds -gt 0.3) { $bps = [int64]($Recv / $Seconds) }
    $eta = -1
    if ($bps -gt 0 -and $Total -gt $Recv) {
        $eta = [int][math]::Ceiling(([double]($Total - $Recv)) / [double]$bps)
    }
    Emit 'download' $pct '' @{ recv = $Recv; total = $Total; bps = $bps; eta = $eta; part = $part }
}

# 单源单次尝试：Range 续传 + 流式写盘 + 进度回推。
# 返回 @{ ok; status; restart; message }：restart=true 表示「丢 .part 从头再来一次」。
function Invoke-SourceOnce([string]$Url, [string]$Dest, [DateTime]$Deadline, $ProxyInfo) {
    $existing = 0
    if (Test-Path -LiteralPath $Dest) {
        try { $existing = [int64](Get-Item -LiteralPath $Dest).Length } catch { $existing = 0 }
    }
    $req = [System.Net.HttpWebRequest]::Create($Url)
    [void](Set-RequestProxy $req $ProxyInfo)
    $req.Method = 'GET'
    $req.AllowAutoRedirect = $true
    $req.UserAgent = 'PerfCapture'
    # 连接超时与总超时分离：慢网下大文件不该被「连接超时」误杀。
    $req.Timeout = [int][math]::Max(1000, [int]$Spec.connectTimeoutMs)
    # 读超时按「停滞」定义：单次 Read 超过 stallTimeoutSec 没有数据才算断流。
    # 2.1.7 用的是 readTimeoutSec(30s)，接到一个只吐几十字节的连接上会白等 30 秒。
    $stallSec = if ([int]$Spec.stallTimeoutSec -ge 5) { [int]$Spec.stallTimeoutSec } else { 20 }
    $req.ReadWriteTimeout = [int]($stallSec * 1000)
    if ($existing -gt 0) { [void]$req.AddRange([int64]$existing) }

    $resp = $null
    try { $resp = $req.GetResponse() }
    catch [System.Net.WebException] {
        $we = $_.Exception
        $status = 0
        try { if ($we.Response) { $status = [int]$we.Response.StatusCode } } catch { }
        if ($status -eq 416 -and $existing -gt 0) {
            # .part 与服务端内容对不上（比整包还大 / 服务端不接受这一段 Range）：丢掉重下。
            try { Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue } catch { }
            return @{ ok = $false; status = 416; restart = $true; message = 'rangeNotSatisfiable' }
        }
        $msg = [string]$we.Message
        if ($we.Status -eq [System.Net.WebExceptionStatus]::Timeout) { $msg = 'connectTimeout' }
        return @{ ok = $false; status = $status; restart = $false; message = $msg }
    } catch {
        return @{ ok = $false; status = 0; restart = $false; message = $_.Exception.Message }
    }

    $code = [int]$resp.StatusCode
    # 服务端返回 200 = 不支持 Range 或忽略了我们那一段：安全回退整包覆盖，绝不拼出半对半错的包。
    $append = ($code -eq 206 -and $existing -gt 0)
    $total = [int64]$resp.ContentLength
    if ($append) { if ($total -ge 0) { $total += $existing } } else { $existing = 0 }
    if ($total -gt [int64]$Spec.maxBytes) {
        try { $resp.Close() } catch { }
        return @{ ok = $false; status = $code; restart = $false; message = 'archiveTooLarge' }
    }

    $recv = $existing
    # 预算按「剩余体积 / 最低可接受速度」推导（2.1.8）：固定 90 秒对 17 MB 的包只允许 ≥200 KB/s，
    # 跨境链路掉到 150 KB/s 就必然失败。这里取 max(原预算, 剩余体积/128KBps×2)，慢但活着的连接能下完；
    # 真正的「卡死」由 stallTimeoutSec 的单次读超时兜住，不会无限等。
    $budgetDeadline = $Deadline
    if ($total -gt $recv) {
        $needSec = [int][math]::Ceiling(([double]($total - $recv)) / 131072.0) * 2
        if ($needSec -lt 60) { $needSec = 60 }
        $cand = [DateTime]::UtcNow.AddSeconds($needSec)
        if ($cand -gt $budgetDeadline) { $budgetDeadline = $cand }
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastEmit = 0
    $fs = $null
    $stream = $null
    try {
        $mode = if ($append) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
        $fs = New-Object System.IO.FileStream($Dest, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream = $resp.GetResponseStream()
        $buf = New-Object byte[] 65536
        while ($true) {
            if (Test-ProvisionCancel) { throw 'cancelled' }
            if ([DateTime]::UtcNow -gt $budgetDeadline) { throw 'downloadTimeout' }
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $fs.Write($buf, 0, $n)
            $recv += $n
            # 全程检查上限：不等到下完才发现磁盘被打满
            if ($recv -gt [int64]$Spec.maxBytes) { throw 'archiveTooLarge' }
            if (($sw.ElapsedMilliseconds - $lastEmit) -ge [int]$Spec.progressIntervalMs) {
                $lastEmit = $sw.ElapsedMilliseconds
                Send-DownloadProgress $recv $total $sw.Elapsed.TotalSeconds
            }
        }
        $fs.Flush()
    } catch {
        $msg = $_.Exception.Message
        try { if ($fs) { $fs.Dispose(); $fs = $null } } catch { }
        try { if ($stream) { $stream.Dispose(); $stream = $null } } catch { }
        try { $resp.Close() } catch { }
        return @{ ok = $false; status = 0; restart = $false; message = $msg }
    } finally {
        try { if ($fs) { $fs.Dispose() } } catch { }
        try { if ($stream) { $stream.Dispose() } } catch { }
        try { $resp.Close() } catch { }
    }
    Send-DownloadProgress $recv $total $sw.Elapsed.TotalSeconds
    return @{ ok = $true; status = $code; restart = $false; message = ''; bytes = $recv }
}

# ---------- 运行时事实（E3：共享内存未就绪细分） ----------
function Get-ShmFacts([string]$LastReason) {
    $obj = 'no'
    try {
        $m = [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting([string]$Spec.shmName)
        $m.Dispose(); $obj = 'yes'
    } catch { }
    $procState = 'unknown'
    try {
        if ($startedProc) {
            if ($startedProc.HasExited) { $procState = ('exited:' + $startedProc.ExitCode) } else { $procState = 'alive' }
        }
    } catch { }
    $frames = if ($LastReason) { ('lastReason=' + $LastReason) } else { 'none' }
    return ('shm=' + $obj + ' process=' + $procState + ' frames=' + $frames)
}

$targetExisted = $false
$createdTarget = $false
$startedProc   = $null
$archivePath   = ''
$partPath      = ''   # 下载临时文件；默认回滚必删（半截包绝不能被当成缓存）
# 但「全源都不可达」属于网络问题而非包问题：保留 .part，用户网络恢复后重试可以续传，
# 不必把已经下了一大半的 18 MB 再走一遍。取消 / 哈希不符 / 安装失败仍然删。
$keepPartOnFail = $false
$workDir       = ''
$actualSha     = ''
$timeline      = New-Object System.Collections.Generic.List[string]
$sourceLog     = New-Object System.Collections.Generic.List[string]
$diagFacts     = @{ installer = ''; installerExit = ''; runtime = '' }

function Invoke-ProvisionRollback {
    try { if ($startedProc -and -not $startedProc.HasExited) { Stop-Process -Id $startedProc.Id -Force -ErrorAction SilentlyContinue } } catch { }
    try { if ($workDir -and (Test-Path -LiteralPath $workDir)) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
    if (-not $keepPartOnFail) {
        try { if ($partPath -and (Test-Path -LiteralPath $partPath)) { Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue } } catch { }
    }
    # 回滚必须连系统级注册一起撤：安装阶段可能已经启动过一次并写入了 Vulkan 层，
    # 目录一删这些注册就指向不存在的 DLL，游戏的 Vulkan 初始化会直接失败。
    try {
        $rollbackRoot = ''
        if ($Spec -and $Spec.targetDir) { $rollbackRoot = [System.IO.Path]::GetFullPath([string]$Spec.targetDir) }
        if ($rollbackRoot -and (Get-Command Clear-ExtensionSystemTraces -ErrorAction SilentlyContinue)) {
            [void](Clear-ExtensionSystemTraces ([string]$Spec.id) $rollbackRoot)
        }
    } catch { }
    # 已通过 SHA-256 的归档属于「可信输入」，回滚保留：下次重试直接命中缓存，不再重下 17 MB。
    # 未通过校验的包在 verify 阶段显式删除，不会被误缓存。
    try { if ($createdTarget -and -not $targetExisted -and (Test-Path -LiteralPath $Spec.targetDir)) { Remove-Item -LiteralPath $Spec.targetDir -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}

try {
    # ---- 1. prepare：路径与 token 全部来自注册表 ----
    Emit 'prepare' 4
    try {
        Assert-NotCancelled
        $cacheDir  = [System.IO.Path]::GetFullPath([string]$Spec.cacheDir)
        $targetDir = [System.IO.Path]::GetFullPath([string]$Spec.targetDir)
        if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
        $targetExisted = Test-Path -LiteralPath $targetDir
        if (-not $targetExisted) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null; $createdTarget = $true }
        $tokens = @{
            DIR     = $targetDir
            CACHE   = $cacheDir
            ID      = [string]$Spec.id
            VERSION = [string]$Spec.version
        }
        $archivePath = [System.IO.Path]::Combine($cacheDir, [string]$Spec.archiveName)
        $partPath    = $archivePath + '.part'
    } catch { return Fail-Stage 'prepare' $_.Exception.Message }

    # ---- 2. download：先查已验证缓存，未命中才下载（流式进度 / Range 续传 / 多源回退） ----
    Emit 'download' 12
    try {
        $cacheHit = $false
        if (Test-Path -LiteralPath $archivePath) {
            $cacheHit = ((Get-Sha256 $archivePath) -eq ([string]$Spec.sha256).ToUpperInvariant())
        }
        if ($cacheHit) {
            # 缓存命中：命中前已重新算过哈希，不存在「半截包被当缓存」的情况。
            Emit 'download' 30 'cacheHit'
        } elseif ([string]$Spec.sourceKind -eq 'http') {
            Assert-NotCancelled
            $sources = @(Get-ProvisionSources)
            if (-not $sources.Count) { throw 'noSource' }
            # 先探测再下载：把「逐个源各等一次连接超时」压成一次并发探测，快的源先上。
            $probe = Select-ProvisionSources $sources
            $sourceLog.Add('proxy ' + $proxyInfo.label)
            foreach ($f in @($probe.facts)) { if ($f) { $sourceLog.Add([string]$f) } }
            $sources = @($probe.order)
            $ok = $false
            foreach ($src in $sources) {
                $attempt = 0
                while ($attempt -lt 2) {
                    $attempt++
                    Assert-NotCancelled
                    # 每个源独立预算：首选源慢死时，备用源仍然拿得到完整时间。
                    $deadline = [DateTime]::UtcNow.AddSeconds([int]$Spec.timeoutSec)
                    $r = Invoke-SourceOnce $src $partPath $deadline $proxyInfo
                    # 代理连接失败（含 407 凭据问题）才直连重试；404/403 是源本身的问题，重试没有意义。
                    if (-not $r.ok -and $proxyInfo.active -and ($r.status -eq 0 -or $r.status -eq 407) -and
                        $r.message -notmatch 'cancelled|archiveTooLarge|downloadTimeout') {
                        $sourceLog.Add((Get-SafeUrl $src) + ' -> 代理失败，直连重试一次')
                        $r = Invoke-SourceOnce $src $partPath $deadline $directInfo
                    }
                    if ($r.ok) { $ok = $true; break }
                    if ($r.message -eq 'cancelled') { throw 'cancelled' }
                    $sourceLog.Add((Get-SafeUrl $src) + ' -> ' + $r.status + ' / ' + $r.message)
                    if ($r.restart) { continue }   # 416 / Range 不可用：丢掉 .part 再来一次
                    # 只有「连接阶段失败」值得原地重试一次（握手抖动）；
                    # 断流/中途失败重试同一个源只是再等一个超时，直接换源才有意义。
                    if ($r.message -match 'connectTimeout|refused|无法连接|actively refused' -and $attempt -lt 2) { continue }
                    break
                }
                if ($ok) { break }
            }
            if (-not $ok) {
                # 全源失败 = 网络问题：保留 .part 让用户重试时能续传（不是包有问题）。
                $keepPartOnFail = $true
                $attempts = @($sourceLog | Where-Object { $_ -notmatch '^probe ' })
                $probes = @($sourceLog | Where-Object { $_ -match '^probe ' })
                $detail = '已尝试 ' + $attempts.Count + ' 个源：' + ($attempts -join '；')
                if ($probes.Count) { $detail += '（探测：' + ($probes -join '；') + '）' }
                if ([string]$Spec.pageUrl) {
                    $detail += '。可在扩展卡片点「手动导入」选择自己下载的安装包，或打开官方下载页'
                }
                return Fail-Stage 'download' $detail
            }
            Move-Item -LiteralPath $partPath -Destination $archivePath -Force
        } elseif ([string]$Spec.sourceKind -eq 'file' -and [bool]$Spec.allowLocalSource) {
            Assert-NotCancelled
            if (-not (Test-Path -LiteralPath ([string]$Spec.url))) { throw 'localSourceMissing' }
            Copy-Item -LiteralPath ([string]$Spec.url) -Destination $partPath -Force
            $sourceLog.Add((Get-SafeUrl ([string]$Spec.url)) + ' -> local / ok')
            Move-Item -LiteralPath $partPath -Destination $archivePath -Force
        } else {
            throw 'unsupportedSourceKind'
        }
    } catch { return Fail-Stage 'download' $_.Exception.Message }

    # ---- 3. verify：哈希不通过就删掉错误缓存，整体失败 ----
    Emit 'verify' 32
    try {
        Assert-NotCancelled
        $actualSha = Get-Sha256 $archivePath
        if ($actualSha -ne ([string]$Spec.sha256).ToUpperInvariant()) {
            try { Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue } catch { }
            return Fail-Step 'hashMismatch' ('期望 ' + $Spec.sha256 + '，实际 ' + $actualSha) $true
        }
    } catch { return Fail-Stage 'verify' $_.Exception.Message }

    # ---- 4. extract：解包 → 定位安装器 → 可选安装器哈希与 Authenticode ----
    Emit 'extract' 46
    try {
        Assert-NotCancelled
        $workDir = [System.IO.Path]::Combine($cacheDir, ('work-' + [guid]::NewGuid().ToString('N')))
        Expand-Archive -LiteralPath $archivePath -DestinationPath $workDir -Force
        $installer = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($workDir, [string]$Spec.installerRelative))
        if (-not (Test-Path -LiteralPath $installer)) {
            return Fail-Step 'installerMissing' $installer $true
        }
        if ($Spec.installerSha256 -and (Get-Sha256 $installer) -ne ([string]$Spec.installerSha256).ToUpperInvariant()) {
            return Fail-Step 'installerHashMismatch' '嵌套安装器哈希不符' $true
        }
        if ([bool]$Spec.requireSignature) {
            $sig = Get-AuthenticodeSignature -LiteralPath $installer
            if ($sig.Status -ne 'Valid') {
                return Fail-Step 'signatureInvalid' ([string]$sig.Status) $true
            }
        }
    } catch { return Fail-Stage 'extract' $_.Exception.Message }

    # ---- 5. install：类型自适应静默安装；生产走一次 UAC ----
    Emit 'install' 60
    $installArgs = Expand-Tmpl ([string]$Spec.installArgs) $tokens
    try {
        Assert-NotCancelled
        $plan = Get-InstallerPlan ([string]$Spec.installerKind) $installer $installArgs
        # 提权：注册表没写就用安装器类型的默认值（msi / nsis / inno 需要，script 不需要）。
        $elevate = if ($null -ne $Spec.elevateInstall) { [bool]$Spec.elevateInstall } else { [bool]$plan.elevate }
        $diagFacts['installer'] = [string]$plan.file + ' ' + [string]$plan.args
        $proc = Start-ProvisionProcess $plan.file $plan.args $elevate $true
        $code = $null
        if ($proc) { $code = $proc.ExitCode }
        $diagFacts['installerExit'] = [string]$code
        # 成功码列表来自注册表；没配时按类型给默认（msi 的 3010 = 成功但需重启）。
        $successCodes = @($Spec.installSuccessCodes)
        if (-not $successCodes.Count) {
            if (([string]$Spec.installerKind).ToLowerInvariant() -eq 'msi') { $successCodes = @(0, 3010, 1641) } else { $successCodes = @(0) }
        }
        # 提权进程的 ExitCode 可能是 $null（拿不到句柄）：此时不能直接判失败，交给 verifyRuntime。
        if ($null -ne $code -and $code -notin $successCodes) {
            return Fail-Step 'installFailed' ('安装器退出码 ' + $code) $true
        }
    } catch {
        $msg = $_.Exception.Message
        # 用户主动点掉 UAC 不是故障：不写失败状态，文案明确「未做任何更改」。
        if ($msg -match 'cancel|取消') { return Fail-Stage 'install' $msg 'uacCancelled' }
        return Fail-Stage 'install' $msg
    }

    # ---- 6. configure：只改自己目录里的文件，逐键 merge，不覆盖未知项 ----
    Emit 'configure' 74
    try {
        Assert-NotCancelled
        $cfgMiss = @()
        foreach ($cfg in @($Spec.configFiles)) {
            if (-not $cfg -or -not $cfg.relative -or -not $cfg.entries) { continue }
            $path = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($targetDir, [string]$cfg.relative))
            $entries = @{}
            foreach ($p in $cfg.entries.PSObject.Properties) { $entries[$p.Name] = $p.Value }
            Set-MergedEntries $path $entries
            # 生效验证：写完必须能原样读回。写不进去（权限/只读/被占用）在这里暴露，
            # 而不是等到启动后表现成「配置没生效」让用户猜。
            if ($cfg.verify -ne $false) {
                $map = Get-EntryMap $path
                foreach ($k in $entries.Keys) {
                    $want = [string]$entries[$k]
                    $got = if ($map.ContainsKey([string]$k)) { [string]$map[[string]$k] } else { $null }
                    if ($null -eq $got -or $got -ne $want) {
                        $cfgMiss += ([string]$cfg.relative + '#' + [string]$k)
                    }
                }
            }
        }
        if ($cfgMiss.Count) {
            return Fail-Step 'configureFailed' ('配置回读不一致：' + ($cfgMiss -join ', ')) $true
        }
    } catch { return Fail-Stage 'configure' $_.Exception.Message }

    # ---- 7. start：只启动刚装的副本；用户预装的同名程序不探测、不复用 ----
    Emit 'start' 86
    try {
        Assert-NotCancelled
        $cmd = Expand-Tmpl ([string]$Spec.processCommand) $tokens
        $pargs = Expand-Tmpl ([string]$Spec.processArgs) $tokens
        $startedProc = Start-ProvisionProcess $cmd $pargs $false $false
    } catch { return Fail-Stage 'start' $_.Exception.Message }

    # ---- 8. verifyRuntime：读到可用结构才算成功，不把「进程起来了」当「可用了」 ----
    # 判定口径与状态机一致：待机（noEntry/noFrames/staleData）算就绪；结构不兼容立刻失败并回滚。
    Emit 'verifyRuntime' 94
    try {
        $ready = $false
        $broken = ''
        $brokenDetail = ''
        $lastReason = ''
        $hasReader = [bool](Get-Command Get-RtssFrameSnapshot -ErrorAction SilentlyContinue)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt [int]$Spec.verifyTimeoutMs) {
            Assert-NotCancelled
            if ($hasReader) {
                $snap = Get-RtssFrameSnapshot -ShmName ([string]$Spec.shmName)
                $st = [string]$snap.reason
                if ($st) { $lastReason = $st }
                if (-not $st -or $st -in @('noEntry', 'noFrames', 'staleData')) { $ready = $true; break }
                if ($st -in @('badSignature', 'oldVersion', 'badLayout', 'readException')) {
                    # 结构不兼容不是「还没起来」，等再久也不会好：立即失败，别让用户干等 15 秒。
                    $broken = $st; $brokenDetail = [string]$snap.detail; break
                }
            } else {
                # 退化检查（无读取器）：至少确认共享内存对象存在
                try {
                    $m = [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting([string]$Spec.shmName)
                    $m.Dispose(); $ready = $true; break
                } catch { }
            }
            Start-Sleep -Milliseconds 200
        }
        if ($broken) {
            $diagFacts['runtime'] = Get-ShmFacts $lastReason
            return Fail-Step 'shmIncompatible' ($broken + '：' + $brokenDetail) $true
        }
        if (-not $ready) {
            # 超时不是一句话「未就绪」：把三项事实一起给出，用户/我们都能判断
            # 是进程没起来、对象没建出来，还是建出来了但一直没帧。
            $facts = Get-ShmFacts $lastReason
            $diagFacts['runtime'] = $facts
            return Fail-Step 'shmNotReady' ('等待共享内存超时 ' + $Spec.verifyTimeoutMs + 'ms；' + $facts) $true
        }
        $diagFacts['runtime'] = Get-ShmFacts $lastReason
    } catch { return Fail-Stage 'verifyRuntime' $_.Exception.Message }

    # 成功：清解包中间产物，保留目标目录、已验证缓存与已启动进程。
    try { if ($workDir -and (Test-Path -LiteralPath $workDir)) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
    Emit 'done' 100
    return [pscustomobject]@{
        ok = $true; reason = ''; detail = ''
        pid = [int]$startedProc.Id; installedPath = $targetDir
        version = [string]$Spec.version; rolledBack = $false; diagPath = ''
    }
} catch {
    # 兜底只处理真正未预期异常；阶段异常已在各自 catch 里细分。
    return Fail-Step 'provisionException' ($_.Exception.Message + ' @ line ' + $_.InvocationInfo.ScriptLineNumber) $true
}
'@

# ---------- 由注册表构造供应规格（不硬编码任何值） ----------
function New-ExtensionProvisionSpec {
    param($Entry, [string]$Mode)
    if (-not $Entry) { throw 'entryMissing' }
    $p = $Entry.package
    if (-not $p -or -not $p.kind) { throw 'packageMissing' }
    $id = [string]$Entry.id
    $version = [string]$p.version
    $cacheDir = Join-Path $script:DataDir ('extensions\' + $id + '\cache')
    $targetDir = Join-Path $script:DataDir ('extensions\' + $id + '\vendor')
    $diagDir = if ($script:LogDir) { [string]$script:LogDir } else { Join-Path $script:DataDir 'logs' }

    # 多源：url 是首选（老配置只有它），urls 是配置化备用镜像。全空才算配置错误。
    $urls = @()
    if ($null -ne $p.urls) { $urls = @(@($p.urls) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ }) }

    $spec = @{
        id = $id
        mode = $Mode
        version = $version
        cacheDir = $cacheDir
        targetDir = $targetDir
        diagDir = $diagDir
        sourceKind = if ($p.sourceKind) { [string]$p.sourceKind } else { 'http' }
        allowLocalSource = [bool]$p.allowLocalSource
        url = [string]$p.url
        urls = $urls
        archiveName = if ($p.archiveName) { [string]$p.archiveName } else { ('package-' + $version + '.bin') }
        sha256 = [string]$p.sha256
        maxBytes = if ($p.maxBytes) { [int64]$p.maxBytes } else { 134217728 }
        timeoutSec = if ($p.timeoutSec) { [int]$p.timeoutSec } else { 60 }
        connectTimeoutSec = if ($p.connectTimeoutSec) { [int]$p.connectTimeoutSec } else { 15 }
        readTimeoutSec = if ($p.readTimeoutSec) { [int]$p.readTimeoutSec } else { 30 }
        # 停滞判据：单次 Read 超过这个秒数没有数据就换源（与「总预算」是两件事）。
        # 老配置只有 readTimeoutSec 时用它兜底，但不超过默认值——2.1.7 的 30 秒正是在只吐几十字节的
        # 半死连接上白等的时间。新配置写 stallTimeoutSec 即可。
        stallTimeoutSec = if ($p.stallTimeoutSec) { [int]$p.stallTimeoutSec } elseif ($p.readTimeoutSec) { [int][math]::Min(20, [int]$p.readTimeoutSec) } else { 20 }
        # 探测预算：并发试每个源的首字节，超过这个时间还没回头的视为不可用
        probeTimeoutMs = if ($p.probeTimeoutMs) { [int]$p.probeTimeoutMs } else { 6000 }
        progressIntervalMs = if ($p.progressIntervalMs) { [int]$p.progressIntervalMs } else { 200 }
        # 官方下载页：网络彻底不通时给用户一条人走的路（手动下载 → 手动导入）
        pageUrl = [string]$p.pageUrl
        installerRelative = [string]$p.installerRelative
        installerSha256 = [string]$p.installerSha256
        installerKind = if ($p.installerKind) { [string]$p.installerKind } else { 'nsis' }
        installArgs = [string]$p.installArgs
        installSuccessCodes = if ($p.installSuccessCodes) { @($p.installSuccessCodes) } else { @() }
        # $null = 注册表没写，由安装器类型决定默认值（msi/nsis/inno 需提权，script 不需要）
        elevateInstall = if ($null -ne $p.elevateInstall) { [bool]$p.elevateInstall } else { $null }
        requireSignature = [bool]$p.requireSignature
        configFiles = if ($p.configFiles) { $p.configFiles } else { @() }
        processCommand = [string]$p.processCommand
        processArgs = [string]$p.processArgs
        shmName = [string]$Entry.shmName
        verifyTimeoutMs = if ($p.verifyTimeoutMs) { [int]$p.verifyTimeoutMs } else { 15000 }
        cancelSignal = $script:ExtProvCancel
    }

    # 配置静态自检：在发命令前拦住「字段存在但为空」这类确定性故障。
    # processArgs / installArgs / installerSha256 留空是合法的，不在此处填假参数。
    foreach ($need in 'sha256', 'installerRelative', 'processCommand', 'shmName') {
        if (-not $spec[$need]) { throw ('packageInvalid:' + $need) }
    }
    if (-not $spec.url -and -not $spec.urls.Count) { throw 'packageInvalid:url' }
    if ($spec.sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw 'packageInvalid:sha256Format' }
    if ($spec.installerSha256 -and $spec.installerSha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw 'packageInvalid:installerSha256Format' }
    if ($spec.installerKind -notin @('nsis', 'inno', 'msi', 'script')) { throw 'packageInvalid:installerKind' }
    if ($spec.timeoutSec -lt 1 -or $spec.timeoutSec -gt 600) { throw 'packageInvalid:timeoutSec' }
    if ($spec.connectTimeoutSec -lt 1 -or $spec.connectTimeoutSec -gt 120) { throw 'packageInvalid:connectTimeoutSec' }
    if ($spec.readTimeoutSec -lt 5 -or $spec.readTimeoutSec -gt 300) { throw 'packageInvalid:readTimeoutSec' }
    if ($spec.maxBytes -le 0) { throw 'packageInvalid:maxBytes' }
    if ($spec.verifyTimeoutMs -lt 500 -or $spec.verifyTimeoutMs -gt 120000) { throw 'packageInvalid:verifyTimeoutMs' }
    return $spec
}

# ---------- 进度回推 ----------
function Stop-ExtProvTimer {
    if ($script:ExtProvTimer) {
        try { $script:ExtProvTimer.Stop(); $script:ExtProvTimer.Dispose() } catch { }
        $script:ExtProvTimer = $null
    }
}

function Send-ExtensionProgress {
    param([string]$Id, [string]$Stage, [int]$Pct, [string]$Detail = '')
    Send-ToUi @{ type = 'extensionProgress'; id = $Id; stage = $Stage; pct = $Pct; detail = $Detail }
}

function Drain-ExtProvQueue {
    $item = $null
    while ($script:ExtProvQueue.TryDequeue([ref]$item)) {
        if ($item -and $item.type -eq 'extensionProgress') {
            Send-ToUi $item
        }
    }
}

# ---------- 异步启动 ----------
function Start-ExtensionProvision {
    # PackagePath：用户手动选择的本地安装包（网络不可达时的兜底）。给了就走本地源，
    # 仍然要过注册表里那份 SHA-256 —— 手动导入不等于放宽校验。
    param([string]$Id, [string]$Mode = 'oneclick', [string]$PackagePath = '')   # install / oneclick / enable / restore / import
    $e = Get-ExtensionEntry $Id
    if (-not $e -or -not $e.available) { Send-ExtensionError $Id 'notAvailable'; return $false }
    if ($script:ExtProvCtx) {
        Send-ExtensionError $Id 'provisionBusy'
        return $false
    }
    try { $spec = New-ExtensionProvisionSpec $e $Mode }
    catch {
        Send-ExtensionError $Id ('packageInvalid:' + $_.Exception.Message)
        return $false
    }
    if ($PackagePath) {
        if (-not (Test-Path -LiteralPath $PackagePath)) { Send-ExtensionError $Id 'localPackageMissing'; return $false }
        $spec.sourceKind = 'file'
        $spec.allowLocalSource = $true
        $spec.url = [System.IO.Path]::GetFullPath($PackagePath)
        $spec.urls = @()
    }

    # 每次新供应都重置取消信号：上一轮取消不能污染这一轮。
    $script:ExtProvCancel = @{ requested = $false }
    $spec.cancelSignal = $script:ExtProvCancel

    Drain-ExtProvQueue
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:ExtensionProvisionWorker)
    [void]$ps.AddArgument($spec)
    [void]$ps.AddArgument($script:ExtProvQueue)
    # 把读取器源码随参数带入 worker：运行态校验与运行时采样共用同一份结构定义。
    $readerCode = if ($script:RtssReaderSource) { [string]$script:RtssReaderSource } else { '' }
    [void]$ps.AddArgument($readerCode)
    [void]$ps.AddArgument([string]$script:NetProxyHelper)
    $handle = $ps.BeginInvoke()
    $script:ExtProvCtx = @{ Id = $Id; Mode = $Mode; PS = $ps; Handle = $handle; Started = (Get-Date); Cancel = $script:ExtProvCancel }
    Send-ExtensionProgress $Id 'prepare' 2
    Write-AppLog ('扩展供应开始: ' + $Id + ' / ' + $Mode)

    Stop-ExtProvTimer
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 150
    $timer.add_Tick({
        try { Invoke-ExtProvTick } catch { Write-AppLog ('扩展供应计时器异常: ' + $_.Exception.Message) 'WARN'; Stop-ExtProvTimer }
    })
    $timer.Start()
    $script:ExtProvTimer = $timer
    return $true
}

# 用户取消：只置信号，真正的回滚在 worker 的阶段边界/下载循环里完成。
# 这样「取消」与「失败」走同一条回滚路径，不会出现「取消了但留下半个目录」。
function Stop-ExtensionProvision {
    if (-not $script:ExtProvCtx) { return $false }
    try { $script:ExtProvCtx.Cancel.requested = $true } catch { }
    Write-AppLog ('扩展供应已请求取消: ' + [string]$script:ExtProvCtx.Id)
    return $true
}

function Invoke-ExtProvTick {
    if (-not $script:ExtProvCtx) { Stop-ExtProvTimer; return }
    Drain-ExtProvQueue
    if (-not $script:ExtProvCtx.Handle.IsCompleted) { return }
    $ctx = $script:ExtProvCtx
    $result = $null
    try { $result = @($ctx.PS.EndInvoke($ctx.Handle))[0] } catch { Write-AppLog ('扩展供应结果读取失败: ' + $_.Exception.Message) 'WARN' }
    try { $ctx.PS.Dispose() } catch { }
    Drain-ExtProvQueue
    Stop-ExtProvTimer
    $script:ExtProvCtx = $null
    Complete-ExtensionProvision $ctx $result
}

function Complete-ExtensionProvision {
    param($Ctx, $Result)
    $id = [string]$Ctx.Id
    if (-not $Result -or -not $Result.ok) {
        $why = if ($Result -and $Result.reason) { [string]$Result.reason } else { 'provisionException' }
        $detail = if ($Result -and $Result.detail) { [string]$Result.detail } else { '' }
        Write-AppLog ('扩展供应失败（已回滚）: ' + $id + ' / ' + $why + ' / ' + $detail) 'WARN'
        if ($Result -and $Result.diagPath) { Write-AppLog ('诊断包已写入: ' + [string]$Result.diagPath) }
        if ($script:ExtProcesses.ContainsKey($id)) { [void]$script:ExtProcesses.Remove($id) }
        # detail 一起上屏：用户能看懂「启动阶段：参数不合法」，而不是笼统「安装过程出错」。
        Send-ExtensionError $id $why $detail
        Send-ExtensionList
        return
    }

    $procId = [int]$Result.pid
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($proc) { $script:ExtProcesses[$id] = $proc }
    $script:ExtIpc[$id] = @{ startedAt = (Get-Date); pid = $procId; mode = 'managed-shm'; shmName = (Get-ExtensionEntry $id).shmName }

    $fields = @{
        autoStart        = $true
        installedPath    = [string]$Result.installedPath
        installedVersion = [string]$Result.version
        installPid       = $procId
        startedByUs      = $true
        lastProvision    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        lastNote         = ''
    }
    Set-ExtensionPersistState $id 'installed' '' $fields
    # 新装的副本会带来新的可执行文件：让「候选文件名」缓存失效，否则关闭时认不到它们。
    if (Get-Command Reset-ExtensionRuntimeCache -ErrorAction SilentlyContinue) { Reset-ExtensionRuntimeCache }
    Write-AppLog ('扩展供应成功: ' + $id + ' v' + $Result.version + '（pid=' + $procId + '）')

    if ($Ctx.Mode -ne 'install') {
        Set-ExtensionPersistState $id 'enabled' '' $fields
        # 只有数据源真的切过去了才算「已接管」；否则如实记警告，不写一句假的成功日志。
        if (Set-FpsSource $id) {
            Write-AppLog ('扩展已启用并接管数据源: ' + $id)
        } else {
            Write-AppLog ('扩展已启用但数据源未切换: ' + $id + '（原因见上一条）') 'WARN'
        }
    }
    Send-ExtensionList
}

# ---------- 启动 / 退出钩子 ----------
# 复用已安装副本：只启动自有进程，不重复下载 / 安装 / 写配置。
# 为什么需要它：本工具退出时会结束自有扩展进程；若每次启动都走完整供应，用户每次开软件
# 都要再等一轮安装、再点一次 UAC —— 与「一条龙、不折腾用户」直接冲突。
# 返回三态字符串（调用方据此决定是否进入完整供应）：
#   'started'     已启动，启用完成
#   'blocked'     目录内仍有杀不掉的残留，拒绝启动（已回推错误）—— 不能回退到重装：
#                 重装会重下 17 MB、再弹一次 UAC，而根源是残留而不是缺文件
#   'unavailable' 副本或配置缺失，需要走完整供应
function Start-ExtensionCopy($Entry, [int]$ReadyWaitMs = 4000) {
    if (-not $Entry -or -not $Entry.package) { return 'unavailable' }
    $bag = Get-ExtensionBag
    if (-not $bag.ContainsKey($Entry.id) -or $bag[$Entry.id] -is [string]) { return 'unavailable' }
    $st = $bag[$Entry.id]
    $dir = [string]$st.installedPath
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return 'unavailable' }
    try {
        # 启用前先清掉同一目录下的残留（上次异常退出留下的注入器 / 编码服务）。
        # 不清会形成「旧 hook + 新 hook」双份注入，游戏内问题不但不消失还会叠加。
        $runtime = Stop-ExtensionRuntime $Entry.id -Quiet
        if (-not $runtime.ok) {
            $left = @($runtime.remaining | ForEach-Object { $_.Name + '#' + $_.Id }) -join ', '
            Write-AppLog ('启用前清理残留失败，已拒绝启动以避免双份注入: ' + $Entry.id + ' / ' + $left) 'WARN'
            Send-ExtensionError $Entry.id 'stopIncomplete' $left
            return 'blocked'
        }
        # 启动前先撤掉旧的系统级注册：上次异常退出可能留下指向旧路径的 Vulkan 层项，
        # loader 会照着 JSON 去加载已不存在的 DLL。RTSS 起来后会按当前目录重新注册，清是安全的。
        [void](Clear-ExtensionSystemTraces $Entry.id $dir)
        $spec = New-ExtensionProvisionSpec $Entry 'restore'
        $tokens = @{ DIR = $dir; CACHE = $spec.cacheDir; ID = [string]$Entry.id; VERSION = [string]$spec.version }
        $cmd = Expand-ExtensionTemplate ([string]$spec.processCommand) $tokens
        if (-not $cmd -or -not (Test-Path -LiteralPath $cmd)) { return 'unavailable' }
        $pargs = Expand-ExtensionTemplate ([string]$spec.processArgs) $tokens
        # 与 worker 内 Start-ProvisionProcess 同一条约定：参数为空就不传 ArgumentList。
        $params = @{ FilePath = $cmd; PassThru = $true }
        if (-not [string]::IsNullOrWhiteSpace($pargs)) { $params.ArgumentList = $pargs }
        $p = Start-Process @params
        $script:ExtProcesses[$Entry.id] = $p
        $script:ExtIpc[$Entry.id] = @{ startedAt = (Get-Date); pid = [int]$p.Id; mode = 'managed-shm'; shmName = [string]$Entry.shmName }
        Set-ExtensionPersistState $Entry.id 'enabled' '' @{
            # 复用路径必须把安装信息带上：依赖探测与下次复用都依赖它，丢了就会判成「未安装」。
            installedPath    = $dir
            installedVersion = [string]$st.installedVersion
            installPid       = [int]$p.Id
            startedByUs      = $true
            autoStart        = $true
            lastProvision    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            lastNote         = ''
        }
        # 等共享内存真的建好再切数据源：刚拉起的进程还在初始化，立刻判会闪一下「读取失败」。
        # 看护重启走前台 tick，等待预算调短（1200ms），避免卡住主界面；正常启用仍用默认 4000ms。
        [void](Wait-ExtensionReady $Entry $ReadyWaitMs)
        [void](Set-FpsSource $Entry.id)
        Write-AppLog ('扩展随软件恢复（复用已安装副本，未重装）: ' + $Entry.id + '（pid=' + $p.Id + '）')
        return 'started'
    } catch {
        Write-AppLog ('复用已安装副本失败: ' + $Entry.id + ' / ' + $_.Exception.Message) 'WARN'
        return 'unavailable'
    }
}

function Start-EnabledExtensions {
    if (-not (Get-Command Get-ExtensionRegistry -ErrorAction SilentlyContinue)) { return }
    foreach ($e in (Get-ExtensionRegistry)) {
        if (-not $e.available -or -not $e.package) { continue }
        if ((Get-ExtensionPersistState $e.id) -ne 'enabled') { continue }
        $bag = Get-ExtensionBag
        if ($bag.ContainsKey($e.id) -and $bag[$e.id] -isnot [string] -and
            [bool]$bag[$e.id].autoStart -eq $false) { continue }
        $dep = Test-ExtensionDependency $e
        if ($dep.ok) {
            $procId = 0
            if ($bag.ContainsKey($e.id) -and $bag[$e.id] -isnot [string]) { $procId = [int]($bag[$e.id].installPid) }
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc) { $script:ExtProcesses[$e.id] = $proc }
            [void](Set-FpsSource $e.id)
            Write-AppLog ('扩展随软件恢复: ' + $e.id)
        } else {
            $copy = Start-ExtensionCopy $e
            if ($copy -eq 'blocked') {
                # 残留杀不掉：已回推 stopIncomplete。绝不重装（重装既不解决问题，还多一次 UAC）。
                Write-AppLog ('扩展自启被残留进程阻断，已跳过: ' + $e.id) 'WARN'
            } elseif ($copy -ne 'started') {
                # 副本缺失（或首次自启）：才走带回滚的完整供应。
                Write-AppLog ('扩展自启需重新供应: ' + $e.id + ' / ' + (($dep.missing) -join ',')) 'WARN'
                [void](Start-ExtensionProvision $e.id 'restore')
            }
        }
    }
}
