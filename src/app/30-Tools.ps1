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
            [void]$list.Add([pscustomobject]@{
                skip    = [string]$o.skip
                label   = [string]$o.label
                default = if ($null -eq $o.default) { $true } else { [bool]$o.default }
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
