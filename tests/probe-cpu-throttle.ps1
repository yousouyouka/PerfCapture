# CPU 降频事件日志探针（v2.1.11）
# 验证：
#   - Event 37 XML 解析（命名 Data / 仅有位置 Data / 坏 XML 三类）
#   - 真实查询：本机 System 日志可读 → ok=true；无事件 → count=0（不是失败）
#   - 文案：N/A / 未记录 / 已记录 N 条
#   - 红线：没有 MSR / 内核调用
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-cpu-throttle.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$okText, [string]$badText) { if ($cond) { Ok $okText } else { Bad $badText } }
function Note([string]$m) { Write-Host "  · $m" -ForegroundColor DarkGray }

Write-Host "== CPU 降频事件日志探针 ==" -ForegroundColor Cyan
. (Join-Path $root 'src\app\cpu-throttle.ps1')
Assert ((Get-Command Get-CpuThrottleSummary -ErrorAction SilentlyContinue) -ne $null) '降频模块已加载' '降频模块未加载'

# ---- 命名 Data ----
$xmlNamed = @'
<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><EventData>
<Data Name="Group">0</Data><Data Name="Number">3</Data><Data Name="CapDurationInSeconds">23</Data>
<Data Name="PpcChanges">0</Data><Data Name="TpcChanges">0</Data><Data Name="PccChanges">2</Data>
</EventData></Event>
'@
$p1 = ConvertFrom-KppEventXml $xmlNamed
Assert ($p1.ok -and $p1.group -eq 0 -and $p1.number -eq 3 -and $p1.seconds -eq 23) '命名 Data 解析正确（Group/Number/CapDurationInSeconds）' '命名 Data 解析失败'

# ---- 仅有位置 Data（不同 Windows 版本可能不带 Name）----
$xmlPos = @'
<Event><EventData><Data>1</Data><Data>7</Data><Data>71</Data></EventData></Event>
'@
$p2 = ConvertFrom-KppEventXml $xmlPos
Assert ($p2.ok -and $p2.group -eq 1 -and $p2.number -eq 7 -and $p2.seconds -eq 71) '位置 Data 兜底解析正确' '位置 Data 解析失败'

# ---- 坏输入 ----
$p3 = ConvertFrom-KppEventXml 'not xml at all'
Assert (-not $p3.ok) '坏 XML 不误判为有效事件' '坏 XML 被当成有效事件'
$p4 = ConvertFrom-KppEventXml ''
Assert (-not $p4.ok) '空字符串不误判为有效事件' '空字符串被当成有效事件'

# ---- 真实查询 ----
$since = (Get-Date).AddMinutes(-10)
$s = Get-CpuThrottleSummary -Since $since
Assert ($s.Contains('ok') -and $s.Contains('count') -and $s.Contains('reason')) '汇总对象字段齐全' '汇总对象字段缺失'
if ($s.ok) {
    Assert ($s.count -ge 0) ("System 日志可读：近 10 分钟 Event 37 共 " + $s.count + " 条") '事件条数非法'
    if ($s.count -gt 0) { Note ("涉及逻辑处理器 " + $s.cores + "，最长一次 " + $s.maxSeconds + " 秒；首条 " + $s.firstAt) }
} else {
    Assert ($s.reason -eq 'throttleLogUnavailable') '日志不可读时给出 throttleLogUnavailable' '日志不可读时原因码错误'
    Note '本机系统日志不可读（非管理员或事件日志服务关闭）'
}

# ---- 文案三态 ----
$none = Format-CpuThrottleSummary $s
Assert ([bool]$none) '汇总能生成可读文案' '汇总文案为空'
Assert ((Format-CpuThrottleSummary $null) -eq 'N/A') 'null 汇总 → N/A' 'null 汇总文案错误'
$fakeZero = [ordered]@{ ok = $true; count = 0; cores = 0; maxSeconds = $null; reason = '' }
Assert ((Format-CpuThrottleSummary $fakeZero) -eq '未记录到固件限速') '0 条 → 未记录到固件限速' '0 条文案错误'
$fakeHit = [ordered]@{ ok = $true; count = 2; cores = 3; maxSeconds = 47; reason = '' }
$txt = Format-CpuThrottleSummary $fakeHit
Assert ($txt -match '2 条' -and $txt -match '47' -and $txt -match '3 个') ('已记录文案含条数/时长/核数：' + $txt) ('已记录文案缺字段：' + $txt)
$fakeBad = [ordered]@{ ok = $false; count = 0; cores = 0; maxSeconds = $null; reason = 'throttleLogUnavailable' }
Assert ((Format-CpuThrottleSummary $fakeBad) -match '不可读') '日志不可读 → 明确写「不可读」' '日志不可读文案不明确'

# ---- 静态红线 ----
$thrPs = Get-Content (Join-Path $root 'src\app\cpu-throttle.ps1') -Raw -Encoding UTF8
Assert (-not [regex]::IsMatch($thrPs, 'IA32_THERM_STATUS|Rdmsr|NtQuerySystemInformation')) '没有 MSR / 内核读取（只用事件日志）' '检测到 MSR 读取'

Write-Host ""
if ($fail -eq 0) { Write-Host "== CPU 降频事件日志探针通过 ==" -ForegroundColor Green; exit 0 }
Write-Host ("== 失败 " + $fail + " 项 ==") -ForegroundColor Red
exit 1
