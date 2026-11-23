# 采集可信度判定（纯函数 · 无副作用）
#
# 设计原则：
#   - 只回答「这次采到的数据够不够支撑结论」，不做采集、不读注册表、不写日志、不发 UI 消息。
#     因为无副作用，tests\probe-quality-rules.ps1 可以直接 dot-source 本文件做场景验证。
#   - 判定分三级：
#       blocked  数据不足以支撑结论（样本过少 / 采集中断）
#       caution  可看，但有明确干扰因素（前台占比低 / 传感器缺失 / 有效时长不足）
#       ok       没有发现影响结论的问题
#   - **无法评估的项不列进 checks**。宁可少报，也不许把「没检查」写成「通过」。
#   - 阈值只在本文件定义一次，引擎与探针共用；改阈值不要改调用方。
#
# 与《后续功能规划与优先级.md》F0-1 对应。

$script:QualityMinFrames        = 300    # 低于此帧数，1% Low 与卡顿统计不可靠
$script:QualityMinSeconds       = 10     # 低于此时长，同上
$script:QualityMinForegroundPct = 70     # 前台占比低于此值，说明采集期间被切走
$script:QualityMinGpuSamplePct  = 50     # GPU 指标可用样本低于此比例，GPU 结论需谨慎
$script:QualityMinCoveragePct   = 60     # 有效时长占采集窗口低于此比例，说明中间停帧

# 返回 ordered hashtable，可直接并进 summary / JSON：
#   level  : blocked / caution / ok
#   checks : 数组，每项 { code, level, frames?, seconds?, pct?, samples? }
#            code 是稳定标识，前端据此选文案；value 只放原始数字，不做措辞。
function Get-CaptureQuality {
    param(
        [int]$Frames = 0,
        [double]$EffectiveSeconds = 0,
        [double]$WallSeconds = 0,
        [bool]$Stalled = $false,
        $ForegroundPct = $null,
        [bool]$GpuRequested = $false,
        [int]$SensorSamples = 0,
        [int]$GpuSamplesOk = 0
    )

    $checks = New-Object System.Collections.ArrayList

    # 1) 样本过少 —— 这是唯一会「阻断结论」的情况之一：几百帧算不出可信的 1% Low
    if ($Frames -lt $script:QualityMinFrames -or $EffectiveSeconds -lt $script:QualityMinSeconds) {
        [void]$checks.Add([ordered]@{
            code    = 'fewSamples'
            level   = 'blocked'
            frames  = $Frames
            seconds = [math]::Round($EffectiveSeconds, 1)
        })
    }

    # 2) 采集中断 —— 游戏停止出帧，后面的统计只覆盖前半段
    if ($Stalled) {
        [void]$checks.Add([ordered]@{
            code  = 'stalled'
            level = 'blocked'
        })
    }
    elseif ($WallSeconds -gt 0 -and $EffectiveSeconds -gt 0) {
        # 3) 有效时长明显短于采集窗口（未到中断阈值，但中间有停顿）
        $cover = 100.0 * $EffectiveSeconds / $WallSeconds
        if ($cover -lt $script:QualityMinCoveragePct) {
            [void]$checks.Add([ordered]@{
                code  = 'partial'
                level = 'caution'
                pct   = [math]::Round($cover, 0)
            })
        }
    }

    # 4) 前台占比过低 —— 采集期间被切到别的窗口，帧数据可能混入非游戏画面
    if ($null -ne $ForegroundPct) {
        $fg = [double]$ForegroundPct
        if ($fg -lt $script:QualityMinForegroundPct) {
            [void]$checks.Add([ordered]@{
                code  = 'targetLost'
                level = 'caution'
                pct   = [math]::Round($fg, 0)
            })
        }
    }

    # 5) GPU 传感器可用率过低 —— 用户开着这一项，但大部分采样没读到
    #    只在「用户确实要采」且「有采样行」时评估；两者缺一就不下判断（不写「通过」）
    if ($GpuRequested -and $SensorSamples -gt 0) {
        $okPct = 100.0 * $GpuSamplesOk / $SensorSamples
        if ($okPct -lt $script:QualityMinGpuSamplePct) {
            [void]$checks.Add([ordered]@{
                code    = 'gpuSparse'
                level   = 'caution'
                pct     = [math]::Round($okPct, 0)
                samples = $SensorSamples
            })
        }
    }

    $level = 'ok'
    foreach ($c in $checks) {
        if ($c.level -eq 'blocked') { $level = 'blocked'; break }
        if ($c.level -eq 'caution') { $level = 'caution' }
    }

    return [ordered]@{
        level  = $level
        checks = @($checks)
    }
}
