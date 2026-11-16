# 进程枚举

# ---------- 进程枚举 ----------
function Get-ProcessChoices {
    $skipNames = '^(ApplicationFrameHost|TextInputHost|ShellExperienceHost|SystemSettings|StartMenuExperienceHost|SearchHost|LockApp|PerfCapture)$'
    $list = New-Object System.Collections.ArrayList
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue | Where-Object {
                $_.MainWindowHandle -ne 0 -and $_.ProcessName -notmatch $skipNames
            } | Sort-Object ProcessName, Id)) {
        [void]$list.Add([pscustomobject]@{
            pid  = $p.Id
            name = $p.ProcessName + '.exe'
            text = ('{0}   ·   PID {1}' -f ($p.ProcessName + '.exe'), $p.Id)
        })
    }
    return ,$list.ToArray()
}
# ---------- 指标字典（capture-metrics.json） ----------
# 唯一事实来源：报告板块顺序 + 全部指标 + 暂不可用的原因（三语）。
# 读不到就返回 $null，界面回退到「只显示已采指标」，绝不阻塞启动。
function Get-MetricsDoc {
    $file = Join-Path $script:Root 'capture-metrics.json'
    if (-not (Test-Path $file)) {
        Write-AppLog ('指标字典缺失: ' + $file) 'WARN'
        return $null
    }
    try {
        $doc = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $doc.metrics -or @($doc.metrics).Count -eq 0) {
            Write-AppLog '指标字典解析后没有 metrics，界面将不使用字典' 'WARN'
            return $null
        }
        $na = @(@($doc.metrics) | Where-Object { $_.status -eq 'na' }).Count
        Write-AppLog (('  指标字典: {0} 个指标（{1} 个暂不可用）· {2} 个板块' -f @($doc.metrics).Count, $na, @($doc.modules).Count))
        return $doc
    } catch {
        Write-AppLog ('指标字典解析失败：' + $_.Exception.Message) 'WARN'
        return $null
    }
}
# ---------- 采集项清单（capture-options.json） ----------
# 唯一事实来源：界面按这里的 options 渲染勾选框，引擎按 skip 字符串决定采不采。
# 读不到或解析失败一律返回 $null（界面回退到内置清单），绝不阻塞启动。
function Get-CaptureOptions {
    $file = Join-Path $script:Root 'capture-options.json'
    if (-not (Test-Path $file)) {
        Write-AppLog ('采集项清单缺失: ' + $file) 'WARN'
        return $null
    }
    try {
        $cfg = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        $list = New-Object System.Collections.ArrayList
        foreach ($o in @($cfg.options)) {
            if ($null -eq $o -or -not $o.skip -or -not $o.label) {
                Write-AppLog '采集项清单有无效条目（缺 skip 或 label），已忽略' 'WARN'
                continue
            }
            # kind：core（无条件采集）/ optional（可开关）/ derived（由已采数据算出来）。
            # 旧清单没有 kind，只有 always 布尔 → 兼容成 core（没法判定的派生项退回 optional）
            $kind = if ($o.kind) { [string]$o.kind } elseif ($o.always) { 'core' } else { 'optional' }
            if (@('core', 'optional', 'derived') -notcontains $kind) {
                Write-AppLog ('采集项 ' + $o.skip + ' 的 kind=' + $kind + ' 非法，按 optional 处理') 'WARN'
                $kind = 'optional'
            }
            [void]$list.Add([pscustomobject]@{
                skip    = [string]$o.skip
                label   = [string]$o.label
                kind    = $kind
                default = if ($null -eq $o.default) { $true } else { [bool]$o.default }
                group   = if ($o.group) { [string]$o.group } elseif ($o.module) { [string]$o.module } else { '' }
                always  = ($kind -eq 'core')       # 引擎无条件采集：界面只读、不给开关
                note    = if ($o.note) { [string]$o.note } else { '' }
                tip     = if ($o.tip) { [string]$o.tip } else { '' }
            })
        }
        # 板块分组（界面上把采集项按板块归类；缺省时界面按顺序平铺）
        $groups = New-Object System.Collections.ArrayList
        foreach ($g in @($cfg.groups)) {
            if ($null -eq $g -or -not $g.id) { continue }
            [void]$groups.Add([pscustomobject]@{
                id    = [string]$g.id
                label = if ($g.label) { [string]$g.label } else { '' }
                note  = if ($g.note) { [string]$g.note } else { '' }
            })
        }
        if ($list.Count -eq 0) {
            Write-AppLog '采集项清单解析后为空，界面将使用内置清单' 'WARN'
            return $null
        }
        $hint = ''
        if ($cfg.always -and $cfg.always.label) { $hint = [string]$cfg.always.label }
        # 高级预设（快速 / 标准 / 专业）：界面据此套用时长、勾选项与预热丢弃
        $presets = New-Object System.Collections.ArrayList
        foreach ($p in @($cfg.presets)) {
            if ($null -eq $p -or -not $p.id) { continue }
            $skipList = @()
            foreach ($s in @($p.skip)) { if ($s) { $skipList += [string]$s } }
            [void]$presets.Add([pscustomobject]@{
                id      = [string]$p.id
                label   = [string]$p.label
                seconds = if ($null -eq $p.seconds) { 120 } else { [int]$p.seconds }
                warmup  = if ($null -eq $p.warmup) { 0 } else { [int]$p.warmup }
                skip    = $skipList
            })
        }
        Write-AppLog ('采集项清单已加载: ' + $list.Count + ' 项' + $(if ($presets.Count -gt 0) { '，预设 ' + $presets.Count + ' 档' } else { '' }))
        return [pscustomobject]@{
            schemaVersion = [int]$cfg.schemaVersion
            hint          = $hint
            options       = $list.ToArray()
            presets       = $presets.ToArray()
            groups        = $groups.ToArray()
        }
    } catch {
        Write-AppLog ('采集项清单解析失败，界面将使用内置清单: ' + $_.Exception.Message) 'ERROR'
        return $null
    }
}

# ---------- 打开目录 ----------
function Show-ReportsFolder {
    param([string]$Path = $script:OutDir)
    try {
        if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        $shell = New-Object -ComObject Shell.Application
        $shell.Explore($Path)
        Write-AppLog ('打开目录: ' + $Path)
    } catch {
        Write-AppLog ('打开目录失败: ' + $_.Exception.Message) 'ERROR'
        Send-ToUi @{ type = 'error'; text = ('打开目录失败: ' + $_.Exception.Message) }
    }
}
