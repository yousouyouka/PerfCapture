# 内核网络 ETW 布局验证（需要管理员）：验证 Event 10/11 的属性索引是否为 [0]=PID、[1]=字节数。
# 布局随 Windows 版本可能变化——引擎解析器已做防御校验，本探针用于在人上确认实际布局。
# 用法：管理员 PowerShell 里运行  powershell -STA -NoProfile -ExecutionPolicy Bypass -File tests\probe-net-etw.ps1
# 结果写到 tests\probe-net-etw.log（UTF8），把日志交回即可。
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$log = Join-Path $PSScriptRoot 'probe-net-etw.log'
$out = New-Object System.Collections.Generic.List[string]

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$out.Add("isAdmin=$isAdmin")
if (-not $isAdmin) { $out.Add('需要管理员权限：请在提权的 PowerShell 里运行。'); [IO.File]::WriteAllLines($log, $out, (New-Object Text.UTF8Encoding($true))); exit 1 }

$sess = 'PerfCapNetProbe'
$etl = Join-Path $env:TEMP 'PerfCapture\probe-net.etl'
try { & logman stop $sess -ets 2>$null | Out-Null } catch { }
try {
    if (-not (Test-Path (Join-Path $env:TEMP 'PerfCapture'))) { New-Item -ItemType Directory -Path (Join-Path $env:TEMP 'PerfCapture') -Force | Out-Null }
    if (Test-Path $etl) { Remove-Item $etl -Force -ErrorAction SilentlyContinue }
    $c = & logman create trace $sess -ow -o $etl -p '{7DD42A49-5329-4832-8DFD-43D979153A88}' 0xffffffff -ets 2>&1
    $out.Add('create: ' + (($c | Out-String).Trim() -replace '\r?\n', ' | '))
    # 等 6 秒：后台流量（系统自带的心跳/更新等）足够产生事件
    Start-Sleep -Seconds 6
    $s = & logman stop $sess -ets 2>&1
    $out.Add('stop: ' + (($s | Out-String).Trim() -replace '\r?\n', ' | '))
    $evts = @(Get-WinEvent -Path $etl -Oldest -ErrorAction SilentlyContinue | Where-Object {
            $_.ProviderName -eq 'Microsoft-Windows-Kernel-Network' -and ($_.Id -eq 10 -or $_.Id -eq 11)
        })
    $out.Add("count(10/11)=$($evts.Count)")
    foreach ($e in @($evts | Select-Object -First 6)) {
        $props = ($e.Properties | ForEach-Object { '[' + $_.Value + ']' }) -join ' '
        $out.Add("Id=$($e.Id) TimeCreated=$($e.TimeCreated.ToString('HH:mm:ss')) props: $props")
    }
    if ($evts.Count -ge 2) {
        $p0 = $evts[0].Properties[0].Value
        $p1 = $evts[0].Properties[1].Value
        $okPid = ($p0 -is [int] -or ("$p0" -match '^\d+$')) -and ([int]$p0 -ge 4) -and ([int]$p0 -le 999999)
        $okSz = ([int]$p1 -ge 0) -and ([int]$p1 -le 1GB)
        $out.Add("check: props[0] 疑似 PID=$okPid ($p0) · props[1] 疑似 size=$okSz ($p1)")
        $out.Add('结论：若两项都为 True，则引擎的 [0]=PID/[1]=size 解析正确；若为 False，把上面的 props 明细交回调整索引。')
    } else {
        $out.Add('事件不足：6 秒窗口内没有 10/11 事件（本机几乎无流量？），换网络活跃时段再跑。')
    }
} catch {
    $out.Add('ERROR: ' + $_.Exception.Message)
}
[IO.File]::WriteAllLines($log, $out, (New-Object Text.UTF8Encoding($true)))
Write-Host ('完成：' + $log)
