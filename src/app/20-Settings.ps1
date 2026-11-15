# 配置读写：所有来自磁盘 / 前端的值都必须过校验，越界或类型不符就忽略并记日志

function New-DefaultConfig {
    [pscustomobject]@{
        theme = 'system'; seconds = 120; minimize = $true; sound = $true; skip = ''
        # 采集预设：standard 是默认档；warmup = 预热丢弃秒数（引擎 -WarmupSec）
        preset = 'standard'; warmup = 3
        language = 'zh-CN'
        lastPid = 0; windowW = 1180; windowH = 780
        # 检查更新：auto 关掉后不再自动查；skippedVersion 是用户点过「跳过此版本」的版本号
        updateCheck = @{ auto = $true; lastCheckAt = ''; skippedVersion = '' }
        overlay     = @{ visible = $false; x = -1; y = -1; opacity = 0.9; collapsed = $false }
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
        'skip'     { if ($Value -is [string]) { $script:Cfg.skip = $Value } }
        'preset'   {
            # 只接受清单里存在的档位；空串 = 自定义
            if ($Value -is [string] -and ($Value -eq '' -or $Value -in @('quick', 'standard', 'pro'))) { $script:Cfg.preset = [string]$Value }
            else { Write-AppLog ("配置 preset=$Value 非法，已忽略") 'WARN' }
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
        default { Write-AppLog ("未知配置项 $Key，已忽略") 'WARN' }
    }
}

# ---------- 载入 ----------
$script:Cfg = New-DefaultConfig
if (Test-Path $script:CfgPath) {
    try {
        $j = Get-Content $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in 'theme', 'language', 'seconds', 'minimize', 'sound', 'skip', 'lastPid', 'windowW', 'windowH') {
            if ($null -ne $j.$k) { Set-ConfigValue $k $j.$k }
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
