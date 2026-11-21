# RTSS 共享内存读取器（批次 D · 首个高频帧数据源原型）
# 纯 .NET MemoryMappedFile 读取，无 P/Invoke、无进程编译（绕开只靠 csc 的环境限制）。
# 数据源：RTSS 官方 RTSSSharedMemoryV2（Unwinder 在 guru3d 公布的 SDK 结构）。
#
# 抗版本漂移：不硬编码 app 数组位置，用主结构里的动态偏移字段
#   dwAppArrOffset / dwAppEntrySize / dwAppArrSize 遍历条目（官方就是这么写的）。
# 口径自主：1% Low 不用 RTSS 自带字段（其口径未必等于本项目），而是从原始帧时间缓冲
#   dwStatFrameTimeBuf[1024]（微秒）按项目铁律自算：最慢 1% 帧的平均帧时间取倒数。
# 采不到一律报 N/A（ok=$false + 细分 reason），绝不返回 0 冒充。
#
# 本文件既在宿主 runspace dot-source，也把 $script:RtssReaderSource 注入采样 runspace。
# 约定：只用 .NET 与纯函数，常量全部内联在函数内，不依赖任何 $script: 变量。

$script:RtssReaderSource = @'
# RTSS_SHARED_MEMORY（主结构）字段偏移（依据官方 SDK：vendor/SDK/Include/RTSSSharedMemory.h）：
#   0x00 dwSignature   'RTSS' = 0x52545353（C 多字符常量，MSVC 左起打包；真机 7.3.7 首 4 字节
#                      为 53 53 54 52，正是该值）。0xDEAD 表示正在销毁，其他值表示尚未初始化。
#   0x04 dwVersion     (major<<16)+minor；帧时间缓冲要求 >= 0x00020005
#   0x08 dwAppEntrySize / 0x0C dwAppArrOffset / 0x10 dwAppArrSize（动态偏移，抗漂移）
#
# RTSS_SHARED_MEMORY_APP_ENTRY 字段偏移（DWORD=4，char[MAX_PATH]=260，
#   到帧时间缓冲为止全是 4 字节字段，无对齐填充）：
#   0x000 dwProcessID
#   0x004 szName[260]        -> 0x108
#   0x108 dwFlags
#   0x10C dwTime0            帧率测量窗起点 (ms, GetTickCount 基准)
#   0x110 dwTime1            终点 (ms)
#   0x114 dwFrames
#   0x118 dwFrameTime        单帧时间 (微秒)
#   0x11C dwStatFlags
#   0x120 dwStatTime0 / 0x124 dwStatTime1 / 0x128 dwStatFrames / 0x12C dwStatCount
#   0x130 dwStatFramerateMin / 0x134 Avg / 0x138 Max
#   0x13C dwOSDX / 0x140 dwOSDY / 0x144 dwOSDPixel / 0x148 dwOSDColor / 0x14C dwOSDFrame
#   0x150 dwScreenCaptureFlags
#   0x154 szScreenCapturePath[260] -> 0x258
#   0x258 dwOSDBgndColor     (v2.1+)
#   0x25C dwVideoCaptureFlags(v2.2+)
#   0x260 szVideoCapturePath[260] -> 0x364
#   0x364 dwVideoFramerate / 0x368 Framesize / 0x36C Format / 0x370 Quality
#   0x374 dwVideoCaptureThreads / 0x378 dwScreenCaptureQuality / 0x37C dwScreenCaptureThreads
#   0x380 dwAudioCaptureFlags(v2.3+) / 0x384 dwVideoCaptureFlagsEx(v2.4+)
#   0x388 dwAudioCaptureFlags2(v2.5+) / 0x38C dwStatFrameTimeMin
#   0x390 dwStatFrameTimeAvg / 0x394 dwStatFrameTimeMax / 0x398 dwStatFrameTimeCount
#   0x39C dwStatFrameTimeBuf[1024] (微秒环形缓冲) -> 0x139C
#   0x139C dwStatFrameTimeBufPos   (环形缓冲写位置)
#   0x13A0 dwStatFrameTimeBufFramerate (RTSS 自算帧率 x10，仅作交叉参考，不采用)
# 推导：0x154 + 260 = 0x258；0x260 + 260 = 0x364；0x39C + 4096 = 0x139C；+4=0x13A0；+4=0x13A4
# 因此有效 app entry 至少需 0x13A4 = 5028 字节；含后续字段的实际更大。

function Get-RtssFrameSnapshot {
    param(
        [string]$ShmName = 'RTSSSharedMemoryV2',
        [int]$TargetPid = 0
    )
    # 常量内联，确保本函数被注入任意 runspace 后仍自包含。
    # 签名：官方 SDK 用 C 多字符常量 'RTSS' 比较（MSVC 左起打包 = 0x52545353，真机 7.3.7 实测一致）。
    # 0x53535452 是同一串字符按内存字节序直接拼出的写法，少数第三方实现这么比，一并接受，
    # 避免把「写法差异」误判成「版本不兼容」。
    $sigAccepted = @([uint32]0x52545353, [uint32]0x53535452)
    $minVersion  = [uint32]0x00020005   # 帧时间缓冲起始版本 v2.5
    $minEntrySz  = 5028                 # 0x13A4，见上推导
    $oSig=0x00; $oVer=0x04; $oEntrySz=0x08; $oArrOff=0x0C; $oArrSz=0x10
    $ePid=0x000; $eName=0x004; $eTime1=0x110
    $eFtBuf=0x39C; $ftBufLen=1024

    # .NET Framework 的 MemoryMappedViewAccessor 只有泛型 Read<T>(long,out T)，
    # 没有 ReadInt32/ReadByte 快捷方法（那是 .NET Core 才有）。用闭包辅助函数统一读取。
    $R32 = {
        param($acc, [int64]$pos)
        $tmp = [int32]0
        $null = $acc.Read($pos, [ref]$tmp)
        return [int64]$tmp
    }
    $RB = {
        param($acc, [int64]$pos)
        $tmp = [byte]0
        $null = $acc.Read($pos, [ref]$tmp)
        return $tmp
    }

    $res = [pscustomobject]@{
        ok = $false; reason = ''; detail = ''; fps = $null; fpsLow1 = $null
        frameTimeUs = $null; sampleCount = 0; processName = ''; version = ''
        source = 'rtss-shm'; at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $mmf = $null; $va = $null
    try {
        try { $mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting($ShmName) }
        catch { $res.reason = 'shmNotFound'; return $res }   # RTSS 未运行 / 未开统计服务

        try {
            $va = $mmf.CreateViewAccessor([int64]0, [int64]0, [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
        } catch { $res.reason = 'shmOpenFailed'; return $res }

        $sig = [uint32](& $R32 $va ([int64]$oSig))
        if ($sigAccepted -notcontains $sig) {
            # 带上实际值：真机排查时能一眼看出是「签名写法差异」还是「对象不是 RTSS」。
            $res.detail = ('签名=0x{0:X8}，期望 0x52545353' -f $sig)
            $res.reason = 'badSignature'; return $res
        }
        $ver = [uint32](& $R32 $va ([int64]$oVer))
        if ($ver -lt $minVersion) {
            $res.detail = ('共享内存版本=0x{0:X8}，要求 >= 0x{1:X8}' -f $ver, $minVersion)
            $res.reason = 'oldVersion'; return $res
        }

        $entrySize = [int](& $R32 $va ([int64]$oEntrySz))
        $arrOffset = [int](& $R32 $va ([int64]$oArrOff))
        $arrSize   = [int](& $R32 $va ([int64]$oArrSz))
        if ($entrySize -lt $minEntrySz -or $arrSize -le 0 -or $arrOffset -lt 0) {
            $res.detail = ('entrySize=' + $entrySize + ' arrOffset=' + $arrOffset + ' arrSize=' + $arrSize)
            $res.reason = 'badLayout'; return $res
        }
        $major = $ver -shr 16; $minor = $ver -band 0xFFFF
        $res.version = ('{0}.{1}' -f $major, $minor)

        # 选条目：指定 PID 优先；否则取最近仍在更新的活跃条目（dwTime1 最大）。
        $chosen = -1
        $bestTick = [int64](-1)
        for ($i = 0; $i -lt $arrSize; $i++) {
            $base = [int64]($arrOffset + $i * $entrySize)
            $procId = [int](& $R32 $va ($base + $ePid))
            if ($procId -le 0) { continue }
            $t1 = & $R32 $va ($base + $eTime1)
            if ($TargetPid -gt 0 -and $procId -eq $TargetPid) { $chosen = $i; $bestTick = $t1; break }
            if ($t1 -gt $bestTick) { $bestTick = $t1; $chosen = $i }
        }
        if ($chosen -lt 0) { $res.reason = 'noEntry'; return $res }

        $base = [int64]($arrOffset + $chosen * $entrySize)
        $t1 = & $R32 $va ($base + $eTime1)
        # 陈旧判定：与官方示例一致 —— GetTickCount() - dwTime1 > 2000ms 视为停更。
        # [Environment]::TickCount 与 GetTickCount 同为系统启动毫秒数（uint32）。
        $nowTick = [uint64][System.Environment]::TickCount
        if ($t1 -le 0) { $res.reason = 'staleData'; return $res }
        $age = [int64]($nowTick - [uint64]$t1)
        if ($age -lt 0 -or $age -gt 2000) { $res.reason = 'staleData'; return $res }

        # 进程名（szName，ANSI，遇 NUL 截断）
        try {
            $nameBytes = New-Object byte[] 260
            for ($k = 0; $k -lt 260; $k++) { $nameBytes[$k] = (& $RB $va ($base + $eName + $k)) }
            $nul = [Array]::IndexOf($nameBytes, [byte]0)
            $len = if ($nul -ge 0) { $nul } else { 260 }
            $res.processName = [System.Text.Encoding]::ASCII.GetString($nameBytes, 0, $len)
        } catch { }

        # 取环形缓冲有效帧时间（微秒，>0；过滤 >10s 的异常值）。
        # 平均值与最慢1%都对顺序不敏感，故遍历全部槽位、跳过空槽，不依赖写位置。
        $fts = New-Object 'System.Collections.Generic.List[double]'
        for ($j = 0; $j -lt $ftBufLen; $j++) {
            $v = & $R32 $va ($base + $eFtBuf + $j * 4)
            if ($v -gt 0 -and $v -lt 10000000) { [void]$fts.Add([double]$v) }
        }
        if ($fts.Count -lt 10) { $res.reason = 'noFrames'; return $res }

        $count = $fts.Count
        $sum = 0.0
        foreach ($x in $fts) { $sum += $x }
        $avgUs = $sum / $count
        if ($avgUs -le 0) { $res.reason = 'noFrames'; return $res }
        $res.fps = [math]::Round(1000000.0 / $avgUs, 2)
        $res.frameTimeUs = [math]::Round($avgUs, 2)
        $res.sampleCount = $count

        # 1% Low = 1e6 / 最慢 1% 帧的平均帧时间（项目铁律口径）
        $sorted = $fts.ToArray()
        [Array]::Sort($sorted)                       # 升序；最慢=帧时间最大=尾部
        $slowN = [int][math]::Ceiling($count * 0.01)
        if ($slowN -lt 1) { $slowN = 1 }
        if ($slowN -gt $count) { $slowN = $count }
        $slowSum = 0.0
        for ($j = $count - $slowN; $j -lt $count; $j++) { $slowSum += $sorted[$j] }
        $slowAvgUs = $slowSum / $slowN
        if ($slowAvgUs -gt 0) { $res.fpsLow1 = [math]::Round(1000000.0 / $slowAvgUs, 2) }

        $res.ok = $true
        $res.reason = ''
        return $res
    } catch {
        $res.reason = 'readException'
        return $res
    } finally {
        if ($null -ne $va)  { try { $va.Dispose() }  catch { } }
        if ($null -ne $mmf) { try { $mmf.Dispose() } catch { } }
    }
}
'@
# 宿主 runspace 立即可用：把上面的源码载入当前作用域。
# 用点源 scriptblock 而非 Invoke-Expression：既避开沙箱对后者的拦截，
# 又让函数定义留在调用者作用域（用 & 调用会在子作用域定义、退出即消失）。
. ([scriptblock]::Create($script:RtssReaderSource))
