# probe-nvapi-thermal.ps1 —— GPU 热点（gpu.hotspot）原型探针，**只读**
#
# 目的：把「能不能读 GPU 热点温度」从猜测变成结论。
#   调 NvAPI_GPU_GetThermalSettings 枚举传感器，打印每个 sensor 的原始 target 编号与温度，
#   再与 nvidia-smi 的 GPU 温度对照，判断哪个 sensor 是「核心」、有没有「热点」。
#
# 三条验收（《暂不可用与所需工具.md》§2.1）：
#   1. 能枚举出传感器列表，并打印每个 sensor 的 target / 名称；
#   2. **只有能确认某个传感器的语义是 Junction / Hotspot 时**才允许填进 gpu.hotspot；
#   3. 只能确认「GPU Core」时，如实报核心温度，**不许改个名字当热点温度**。
#
# 本探针不写任何配置、不装驱动、不常驻；只调公开的 NVAPI（随 NVIDIA 驱动安装在系统里）。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-nvapi-thermal.ps1

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$ok = 0; $fail = 0
function Ok($m) { Write-Host ("  [OK]   " + $m) -ForegroundColor Green; $script:ok++ }
function Bad($m) { Write-Host ("  [FAIL] " + $m) -ForegroundColor Red; $script:fail++ }
function Info($m) { Write-Host ("         " + $m) -ForegroundColor DarkGray }

Write-Host ''
Write-Host '== GPU 热点温度探针（NVAPI，只读）==' -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------- 0. 前置检查
$nvapiPath = $null
foreach ($p in @("$env:WINDIR\System32\nvapi64.dll", "$env:WINDIR\System32\nvapi.dll")) {
    if (Test-Path -LiteralPath $p) { $nvapiPath = $p; break }
}
if (-not $nvapiPath) {
    Write-Host '  本机没有 nvapi64.dll —— 没有 NVIDIA 驱动，本探针不适用。' -ForegroundColor Yellow
    Write-Host '== 探针结束（N/A）==' -ForegroundColor Yellow
    exit 0
}
Ok ("找到 NVAPI：" + $nvapiPath)

$smiTemp = $null
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($smi) {
    try {
        $raw = & $smi.Source --query-gpu=temperature.gpu --format=csv,noheader 2>$null | Select-Object -First 1
        $t = 0
        if ([int]::TryParse(([string]$raw).Trim(), [ref]$t)) { $smiTemp = $t }
    } catch { }
}
if ($null -ne $smiTemp) { Info ("nvidia-smi 报告的 GPU 温度：" + $smiTemp + " °C（用于交叉校验）") }
else { Info 'nvidia-smi 没给出温度，本次无法交叉校验' }

# ---------------------------------------------------------------- 1. P/Invoke 垫片
# NVAPI 只导出 nvapi_QueryInterface；所有函数都靠固定 ID 取指针。
# 结构按「手写偏移」读写，不用 ByValArray —— 避免封送布局在各版本 .NET 上出现差异。
$cs = @'
using System;
using System.Runtime.InteropServices;

public static class NvApiThermal
{
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibrary(string name);

    [DllImport("kernel32", CharSet = CharSet.Ansi, SetLastError = true)]
    private static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr QueryInterfaceDelegate(uint id);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int InitializeDelegate();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int EnumPhysicalGpusDelegate(IntPtr[] handles, ref uint count);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int GetThermalSettingsDelegate(IntPtr gpu, uint sensorIndex, IntPtr settings);

    private const uint ID_Initialize        = 0x0150E828;
    private const uint ID_EnumPhysicalGPUs  = 0xE5AC921F;
    private const uint ID_GetThermalSettings = 0xE3640A56;

    // NV_GPU_THERMAL_SETTINGS：version(4) + count(4) + sensor[NVAPI_MAX_THERMAL_SENSORS_PER_GPU]
    // 每个 sensor：controller / defaultMinTemp / defaultMaxTemp / currentTemp / target，各 4 字节
    // 注意：NVAPI 头文件里 MAX_THERMAL_SENSORS_PER_GPU = 3（不是 32）。
    // 开成 32 会得到 0xFFFFFFF7 = NVAPI_INCOMPATIBLE_STRUCT_VERSION —— 这正是第一次踩的坑。
    private const int SensorSize = 20;
    private const int MaxSensors = 3;
    private const int StructSize = 8 + SensorSize * MaxSensors;

    public static string Run()
    {
        var sb = new System.Text.StringBuilder();
        IntPtr h = LoadLibrary("nvapi64.dll");
        if (h == IntPtr.Zero) h = LoadLibrary("nvapi.dll");
        if (h == IntPtr.Zero) { sb.AppendLine("LOAD_FAIL|无法加载 nvapi64.dll"); return sb.ToString(); }

        IntPtr qiPtr = GetProcAddress(h, "nvapi_QueryInterface");
        if (qiPtr == IntPtr.Zero) { sb.AppendLine("QI_FAIL|找不到 nvapi_QueryInterface"); return sb.ToString(); }
        var qi = (QueryInterfaceDelegate)Marshal.GetDelegateForFunctionPointer(qiPtr, typeof(QueryInterfaceDelegate));

        IntPtr initPtr = qi(ID_Initialize);
        if (initPtr != IntPtr.Zero)
        {
            var init = (InitializeDelegate)Marshal.GetDelegateForFunctionPointer(initPtr, typeof(InitializeDelegate));
            int irc = init();
            sb.AppendLine("INIT|" + irc);
            // 0 = OK；其它值也继续试（部分驱动/环境下 NvAPI_Initialize 返回非 0 但接口仍可用）
        }
        else sb.AppendLine("INIT|missing");

        IntPtr enumPtr = qi(ID_EnumPhysicalGPUs);
        IntPtr thermPtr = qi(ID_GetThermalSettings);
        if (enumPtr == IntPtr.Zero || thermPtr == IntPtr.Zero)
        {
            sb.AppendLine("IFACE|missing enum=" + (enumPtr != IntPtr.Zero) + " thermal=" + (thermPtr != IntPtr.Zero));
            return sb.ToString();
        }
        var enumGpus = (EnumPhysicalGpusDelegate)Marshal.GetDelegateForFunctionPointer(enumPtr, typeof(EnumPhysicalGpusDelegate));
        var getTherm = (GetThermalSettingsDelegate)Marshal.GetDelegateForFunctionPointer(thermPtr, typeof(GetThermalSettingsDelegate));

        var handles = new IntPtr[64];
        uint count = 0;
        int rc = enumGpus(handles, ref count);
        sb.AppendLine("ENUM|" + rc + "|" + count);
        if (rc != 0) return sb.ToString();

        for (int g = 0; g < count; g++)
        {
            if (handles[g] == IntPtr.Zero) continue;
            IntPtr buf = Marshal.AllocHGlobal(StructSize);
            try
            {
                // 版本号不是 0x00010001！NVAPI 的 MAKE_NVAPI_VERSION 是
                //   (sizeof(struct) | (ver << 16))
                // 低 16 位是**结构大小**。传 0x00010001 等于声称结构只有 1 字节，
                // 驱动会返回 0xFFFFFFF7 = NVAPI_INCOMPATIBLE_STRUCT_VERSION（第二次踩的坑）。
                int[] versions = new int[] { StructSize | (1 << 16), StructSize | (2 << 16) };
                foreach (int ver in versions)
                {
                    for (int i = 0; i < StructSize; i++) Marshal.WriteByte(buf, i, 0);
                    Marshal.WriteInt32(buf, 0, ver);
                    int trc = getTherm(handles[g], 0, buf);   // sensorIndex 0 = 该卡全部传感器
                    if (trc == 0)
                    {
                        int sc = Marshal.ReadInt32(buf, 4);
                        sb.AppendLine("GPU|" + g + "|ver=0x" + ver.ToString("X8") + "|sensors=" + sc);
                        int n = sc; if (n > MaxSensors) n = MaxSensors;
                        for (int i = 0; i < n; i++)
                        {
                            int off = 8 + i * SensorSize;
                            int ctrl   = Marshal.ReadInt32(buf, off);
                            int minT   = Marshal.ReadInt32(buf, off + 4);
                            int maxT   = Marshal.ReadInt32(buf, off + 8);
                            int curT   = Marshal.ReadInt32(buf, off + 12);
                            int target = Marshal.ReadInt32(buf, off + 16);
                            sb.AppendLine("SENSOR|" + g + "|" + i + "|" + ctrl + "|" + target + "|" + curT + "|" + minT + "|" + maxT);
                        }
                        break;
                    }
                    sb.AppendLine("THERM|" + g + "|ver=0x" + ver.ToString("X8") + "|rc=0x" + trc.ToString("X8"));
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
        }
        return sb.ToString();
    }
}
'@

try {
    Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop
    Ok 'P/Invoke 垫片编译通过'
} catch {
    Bad ('垫片编译失败：' + $_.Exception.Message)
    Write-Host ''
    Write-Host '== 探针结束 ==' -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------- 2. 调接口
$raw = [NvApiThermal]::Run()
$lines = @($raw -split "`r?`n" | Where-Object { $_.Trim() })

$initRc = $null; $enumRc = $null; $gpuCount = 0
$sensors = @()
$thermErrors = @()
foreach ($ln in $lines) {
    $f = $ln -split '\|'
    switch ($f[0]) {
        'INIT'   { $initRc = $f[1] }
        'ENUM'   { $enumRc = $f[1]; $gpuCount = [int]$f[2] }
        'THERM'  { $thermErrors += $ln }
        'SENSOR' {
            $sensors += [pscustomobject]@{
                gpu     = [int]$f[1]
                index   = [int]$f[2]
                ctrl    = [int]$f[3]
                target  = [int]$f[4]     # 原始值，不做名字映射（映射正是本次要验证的东西）
                cur     = [int]$f[5]
                minT    = [int]$f[6]
                maxT    = [int]$f[7]
            }
        }
        'LOAD_FAIL' { Bad ('加载 NVAPI 失败：' + $f[1]) }
        'QI_FAIL'   { Bad $f[1] }
        'IFACE'     { Bad ('接口缺失：' + $f[1]) }
    }
}

if ($null -ne $initRc) {
    if ($initRc -in @('0', 'missing')) { Ok ('NvAPI_Initialize 返回 ' + $initRc) }
    else { Info ('NvAPI_Initialize 返回 ' + $initRc + '（非 0 也继续尝试，部分驱动如此）') }
}
if ($null -eq $enumRc) { Bad '没有拿到 EnumPhysicalGPUs 结果' }
elseif ($enumRc -ne '0') { Bad ('EnumPhysicalGPUs 返回 ' + $enumRc) }
else { Ok ('枚举到 ' + $gpuCount + ' 个物理 GPU') }

foreach ($e in $thermErrors) { Info ('调用未成功：' + $e) }

if (@($sensors).Count -eq 0) {
    Bad '一个传感器都没枚举到 —— 说明这条接口在本机这套驱动上不提供逐传感器温度'
} else {
    Ok ('共枚举到 ' + @($sensors).Count + ' 个传感器')
    Write-Host ''
    Write-Host ('  {0,-4} {1,-6} {2,-8} {3,-8} {4,-10} {5}' -f 'GPU', '序号', 'target', '当前°C', '范围°C', '与 nvidia-smi 对比') -ForegroundColor Cyan
    foreach ($s in $sensors) {
        $cmp = ''
        if ($null -ne $smiTemp) {
            $d = $s.cur - $smiTemp
            $cmp = if ($d -eq 0) { '完全一致' } elseif ([math]::Abs($d) -le 2) { '接近（差 ' + $d + '）' } else { '差 ' + $d }
        }
        $range = ('' + $s.minT + '–' + $s.maxT)
        Write-Host ('  {0,-4} {1,-6} {2,-8} {3,-8} {4,-10} {5}' -f $s.gpu, $s.index, $s.target, $s.cur, $range, $cmp)
    }
}

# ---------------------------------------------------------------- 3. 判定（按三条验收）
Write-Host ''
Write-Host '-- 判定 --' -ForegroundColor Cyan

$valid = @($sensors | Where-Object { $_.cur -gt 0 -and $_.cur -lt 150 })
if (@($valid).Count -eq 0) {
    Write-Host '  结论：没有可用的温度读数。gpu.hotspot 维持「暂不可用」。' -ForegroundColor Yellow
} elseif (@($valid).Count -eq 1) {
    # 单传感器是最常见的情况（笔记本尤甚）：根本没有第二个读数可当热点。
    # 这是硬事实，不依赖 target 编号的含义，所以可以直接下结论。
    Write-Host ('  只有 1 个传感器（target=' + $valid[0].target + '，' + $valid[0].cur + ' °C）：') -ForegroundColor Yellow
    Write-Host '  本机没有可区分于核心温度的第二个读数 —— 拿不到热点，gpu.hotspot 维持 N/A。' -ForegroundColor Yellow
    Write-Host '  注意：这唯一的传感器是核心温度，**不能**改名为热点温度。' -ForegroundColor Yellow
} else {
    # 只做「事实陈述」：哪个 sensor 与 nvidia-smi 一致 → 几乎肯定是核心温度。
    $matchCore = @()
    if ($null -ne $smiTemp) {
        $matchCore = @($valid | Where-Object { [math]::Abs($_.cur - $smiTemp) -le 2 })
    }
    if (@($matchCore).Count -gt 0) {
        Write-Host ('  与 nvidia-smi 一致（±2 °C）的传感器：target=' + (($matchCore | ForEach-Object { $_.target }) -join ', ')) -ForegroundColor Yellow
        Write-Host '  → 这些是「核心温度」，**不能**当作热点温度使用。' -ForegroundColor Yellow
    }
    $others = @($valid | Where-Object { $matchCore -notcontains $_ })
    if (@($others).Count -gt 0) {
        Write-Host ('  其余传感器：target=' + (($others | ForEach-Object { $_.target }) -join ', ')) -ForegroundColor Yellow
        Write-Host '  → 可能是热点/显存，但**target 编号的含义未确认**，按规则不许猜。' -ForegroundColor Yellow
        Write-Host '  → 若要转正：需用 NVIDIA 官方文档确认该 target 常量，或与 HWiNFO/GPU-Z 同刻对照。' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '  结论：本次探针**不改变** gpu.hotspot 的状态；除非上面能确认为 Hotspot，否则仍为 N/A。' -ForegroundColor Yellow
}

Write-Host ''
if ($fail -eq 0) { Write-Host '== 探针通过 ==' -ForegroundColor Green }
else { Write-Host ('== 探针结束：' + $fail + ' 项未通过 ==') -ForegroundColor Yellow }
Write-Host ''
Write-Host '提示：target 的原始编号已原样打印。不要按「猜测的映射表」下结论——' -ForegroundColor DarkGray
Write-Host '      本项目的规则是「API 调用成功 ≠ 指标完成」，语义没确认就不进报告。' -ForegroundColor DarkGray
