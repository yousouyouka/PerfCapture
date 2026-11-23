# 历史报告库（2.1.14 / F1-1 · F1-2 · F1-3）
#
# 设计原则：
#   - 只读 reports 目录，不碰采集链路；索引/读取/删除都做成带 -Dir 参数的函数，探针可独立验证。
#   - 索引只取摘要字段，不把整份报告塞进列表（一次最多 60 份，超出如实标注）。
#   - 删除走**回收站**：报告是用户数据，不做静默永久删除（探针用 -Permanent 避免污染回收站）。
#   - 打开文件只允许 reports 目录内的四种后缀，且路径必须落在目录内（防路径穿越）。
#
# 与《后续功能规划与优先级.md》§3.2 对应；完整图表复看仍在采集页（本次不做跨页重渲染）。

$script:ReportMaxItems = 60          # 索引上限：再多的报告列表也没人翻，且解析要花时间
$script:ReportCacheAt = [datetime]::MinValue
$script:ReportCacheItems = @()
$script:ReportCacheTotal = 0

# 报告 id = 文件名（不含扩展名）。只允许字母数字与 . _ -，杜绝任何路径成分。
function Test-ReportId([string]$Id) {
    if (-not $Id) { return $false }
    if ($Id.Length -gt 120) { return $false }
    if ($Id -notmatch '^[A-Za-z0-9._-]+$') { return $false }
    if ($Id -match '\.\.') { return $false }
    return $true
}

# 解析成绝对路径并二次校验是否仍在 reports 目录内；不合法或不存在都返回 $null
function Resolve-ReportFile([string]$Id, [string]$Dir = $script:OutDir, [string]$Ext = '.json') {
    if (-not (Test-ReportId $Id)) { return $null }
    if ($Ext -notin @('.json', '.html', '.presentmon.csv', '.sensors.csv')) { return $null }
    $p = Join-Path $Dir ($Id + $Ext)
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $full = [IO.Path]::GetFullPath($p)
        $base = [IO.Path]::GetFullPath($Dir).TrimEnd('\') + '\'
        if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { return $null }
        return $full
    } catch { return $null }
}

# 读取一份报告的摘要（缺失字段一律 $null，老 schema 也能读）
function Read-ReportSummary([string]$Path) {
    $data = $null
    try { $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if ($null -eq $data) { return $null }
    $env = $data.environment
    $q = $data.quality
    return [ordered]@{
        id          = [IO.Path]::GetFileNameWithoutExtension($Path)
        schema      = [int]($data.schema_version)
        run         = [string]$data.run
        process     = [string]$data.process
        seconds     = $data.captured_seconds
        frames      = $data.frames
        avg         = $data.avg_fps
        low1        = $data.fps_1pct_low
        gpu         = $(if ($env) { [string]$env.gpu_model } else { $null })
        driver      = $(if ($env) { [string]$env.driver_version } else { $null })
        os          = $(if ($env) { [string]$env.os_version } else { $null })
        bios        = $(if ($env) { [string]$env.bios_version } else { $null })
        resolution  = [string]$data.resolution
        quality     = $(if ($q) { [string]$q.level } else { $null })
    }
}

# 扫描目录并按修改时间倒序返回索引；缓存 5 秒，避免每次切页都重扫
function Get-ReportIndex([string]$Dir = $script:OutDir, [switch]$Fresh) {
    if (-not $Fresh -and ((Get-Date) - $script:ReportCacheAt).TotalSeconds -lt 5) {
        return @{ items = $script:ReportCacheItems; total = $script:ReportCacheTotal }
    }
    if (-not (Test-Path -LiteralPath $Dir)) { return @{ items = @(); total = 0 } }
    $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    $total = $files.Count
    $items = New-Object System.Collections.ArrayList
    $epoch = [datetime]'1970-01-01'
    foreach ($f in ($files | Select-Object -First $script:ReportMaxItems)) {
        $s = Read-ReportSummary $f.FullName
        if ($null -eq $s) { continue }   # 解析失败的文件不进列表（不冒充一条记录）
        $s['mtime'] = [int64](($f.LastWriteTime.ToUniversalTime() - $epoch.ToUniversalTime()).TotalMilliseconds)
        [void]$items.Add($s)
    }
    $script:ReportCacheAt = Get-Date
    $script:ReportCacheItems = @($items)
    $script:ReportCacheTotal = $total
    return @{ items = @($items); total = $total }
}

# 该报告当前实际存在哪些伴随文件（按钮只对存在的显示）
function Get-ReportFiles([string]$Id, [string]$Dir = $script:OutDir) {
    $out = New-Object System.Collections.ArrayList
    foreach ($k in @(
            @{ kind = 'json'; ext = '.json' },
            @{ kind = 'html'; ext = '.html' },
            @{ kind = 'pmcsv'; ext = '.presentmon.csv' },
            @{ kind = 'senscsv'; ext = '.sensors.csv' }
        )) {
        $p = Resolve-ReportFile $Id $Dir $k.ext
        if ($p) {
            $sz = 0
            try { $sz = (Get-Item -LiteralPath $p).Length } catch { }
            [void]$out.Add([ordered]@{ kind = $k.kind; bytes = [int64]$sz })
        }
    }
    return @($out)
}

# 删除一份报告（默认只在回收站）：-WithAssets 连 html / csv 一起删
# -Permanent 只给探针与清理用，产品行为永远走回收站
function Remove-ReportFiles([string]$Id, [string]$Dir = $script:OutDir, [switch]$WithAssets, [switch]$Permanent) {
    $json = Resolve-ReportFile $Id $Dir '.json'
    if (-not $json) { return @() }
    $targets = @($json)
    if ($WithAssets) {
        foreach ($ext in @('.html', '.presentmon.csv', '.sensors.csv')) {
            $p = Resolve-ReportFile $Id $Dir $ext
            if ($p) { $targets += $p }
        }
    }
    $removed = New-Object System.Collections.ArrayList
    foreach ($t in $targets) {
        try {
            if ($Permanent) {
                Remove-Item -LiteralPath $t -Force -ErrorAction Stop
            } else {
                if (-not ('Microsoft.VisualBasic.FileIO.FileSystem' -as [type])) {
                    Add-Type -AssemblyName Microsoft.VisualBasic
                }
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                    $t, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
            }
            [void]$removed.Add([IO.Path]::GetFileName($t))
        } catch {
            Write-AppLog ('删除报告失败: ' + $t + ' · ' + $_.Exception.Message) 'WARN'
        }
    }
    $script:ReportCacheAt = [datetime]::MinValue   # 强制下次重扫
    return @($removed)
}

# 打开伴随文件：只认 reports 目录内的四种后缀，用系统默认程序打开
function Open-ReportFile([string]$Id, [string]$Kind, [string]$Dir = $script:OutDir) {
    $map = @{ json = '.json'; html = '.html'; pmcsv = '.presentmon.csv'; senscsv = '.sensors.csv' }
    if (-not $map.ContainsKey([string]$Kind)) { return $false }
    $p = Resolve-ReportFile $Id $Dir $map[[string]$Kind]
    if (-not $p) { return $false }
    try {
        Start-Process -FilePath $p | Out-Null
        return $true
    } catch {
        Write-AppLog ('打开报告文件失败: ' + $p + ' · ' + $_.Exception.Message) 'WARN'
        return $false
    }
}

# ---------- 命令分发（宿主侧）----------
function Invoke-ReportCommand($msg) {
    $cmd = [string]$msg.cmd
    switch ($cmd) {
        'reportsList' {
            $idx = Get-ReportIndex -Fresh
            Send-ToUi @{
                type      = 'reports'
                items     = @($idx.items)
                total     = [int]$idx.total
                truncated = ([int]$idx.total -gt $script:ReportMaxItems)
            }
        }
        'reportDetail' {
            $id = [string]$msg.id
            $p = Resolve-ReportFile $id
            if (-not $p) {
                Send-ToUi @{ type = 'reportDetail'; ok = $false; id = $id; reason = 'notFound' }
                return
            }
            $data = $null
            try { $data = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
            if ($null -eq $data) {
                Send-ToUi @{ type = 'reportDetail'; ok = $false; id = $id; reason = 'parseFailed' }
                return
            }
            Send-ToUi @{
                type  = 'reportDetail'
                ok    = $true
                id    = $id
                data  = $data
                files = @(Get-ReportFiles $id)
            }
        }
        'reportCompare' {
            $ids = @($msg.ids)
            if ($ids.Count -ne 2) {
                Send-ToUi @{ type = 'reportCompare'; ok = $false; reason = 'needTwo' }
                return
            }
            $pair = @()
            foreach ($id in $ids) {
                $p = Resolve-ReportFile ([string]$id)
                $d = $null
                if ($p) { try { $d = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
                if ($null -eq $d) {
                    Send-ToUi @{ type = 'reportCompare'; ok = $false; reason = 'notFound'; id = [string]$id }
                    return
                }
                $pair += $d
            }
            Send-ToUi @{ type = 'reportCompare'; ok = $true; ids = $ids; a = $pair[0]; b = $pair[1] }
        }
        'reportOpenFile' {
            $ok = Open-ReportFile ([string]$msg.id) ([string]$msg.kind)
            if (-not $ok) { Send-ToUi @{ type = 'error'; text = '找不到该报告文件，或格式不支持' } }
        }
        'reportDelete' {
            $removed = @(Remove-ReportFiles ([string]$msg.id) -WithAssets:([bool]$msg.withAssets))
            Send-ToUi @{ type = 'reportDeleted'; id = [string]$msg.id; removed = $removed }
        }
        default { }
    }
}
