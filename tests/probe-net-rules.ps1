# net-rules 探针（2.2.1）：进程级网络归因聚合的纯函数验证
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-net-rules.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\app\net-rules.ps1')

$pass = 0; $fail = 0
function Ok($m) { Write-Host "  ✓ $m" -ForegroundColor Green; $script:pass++ }
function Bad($m) { Write-Host "  ✗ $m" -ForegroundColor Red; $script:fail++ }
function Assert($c, $ok, $bad) { if ($c) { Ok $ok } else { Bad $bad } }

Write-Host '== net-rules：进程归因聚合 ==' -ForegroundColor Cyan

# 1. 基本聚合：游戏 + 多个其它进程
$rows = @(
    @{ pid = 1000; dir = 'recv'; size = 1024 },
    @{ pid = 1000; dir = 'recv'; size = 2048 },
    @{ pid = 1000; dir = 'sent'; size = 512 },
    @{ pid = 2000; dir = 'recv'; size = 4096 },
    @{ pid = 2000; dir = 'sent'; size = 4096 },
    @{ pid = 3000; dir = 'recv'; size = 100 },
    @{ pid = 4000; dir = 'sent'; size = 50 }
)
$r = Get-NetProcessEventStats -Rows $rows -GamePid 1000
Assert ($r.validRows -eq 7) '7 行全部有效' ("实际 " + $r.validRows)
Assert ($r.game.recv -eq 3072 -and $r.game.sent -eq 512) '游戏进程收发聚合正确'
Assert ($r.total.recv -eq (3072 + 4096 + 100) -and $r.total.sent -eq (512 + 4096 + 50)) '总量聚合正确'
Assert ($r.procCount -eq 4) '4 个进程'
Assert ($r.other[0].pid -eq 2000) 'Top1 是吞吐最大的 2000'
Assert ($r.other[0].total -eq 8192) 'Top1 合计 8192'
Assert (@($r.other | Where-Object { $_.pid -eq 1000 }).Count -eq 0) '游戏进程不进 Top 列表'

# 2. Top 截断
$r2 = Get-NetProcessEventStats -Rows $rows -GamePid 1000 -Top 2
Assert (@($r2.other).Count -eq 2) 'Top=2 截断生效' ("实际 " + @($r2.other).Count)

# 3. 防御校验：坏行丢弃且计数
$badRows = @(
    @{ pid = 0; dir = 'recv'; size = 10 },            # PID 非法
    @{ pid = -5; dir = 'recv'; size = 10 },
    @{ pid = 1000; dir = 'weird'; size = 10 },        # 方向非法
    @{ pid = 1000; dir = 'recv'; size = -1 },         # 负字节
    @{ pid = 1000; dir = 'recv'; size = 2GB },        # 超上限
    @{ pid = 'abc'; dir = 'recv'; size = 10 },        # 类型错
    @{ pid = 1000; dir = 'recv'; size = $null }       # 空 size
)
$r3 = Get-NetProcessEventStats -Rows $badRows -GamePid 1000
Assert ($r3.validRows -eq 0) '全部坏行被丢弃' ("有效 " + $r3.validRows)
Assert ($r3.invalidRows -eq 7) '坏行计数 7' ("实际 " + $r3.invalidRows)
Assert ($r3.total.recv -eq 0 -and $r3.total.sent -eq 0) '不编 0 之外的数'

# 4. 无游戏 PID：game 归零但不崩
$r4 = Get-NetProcessEventStats -Rows @(@{ pid = 1000; dir = 'recv'; size = 10 }) -GamePid 0
Assert ($r4.game.recv -eq 0 -and $r4.validRows -eq 1) '无 GamePid 时 game=0 但行有效'
Assert ($r4.other[0].pid -eq 1000) '无 GamePid 时所有进程都进 Top'

# 5. 空输入
$r5 = Get-NetProcessEventStats -Rows @() -GamePid 1000
Assert ($r5.validRows -eq 0 -and $r5.procCount -eq 0) '空输入不崩'

# 6. 端口服务推断
Assert ((Get-NetServiceName -Port 443 -Proto 'TCP') -eq 'HTTPS') 'TCP 443 = HTTPS'
Assert ((Get-NetServiceName -Port 443 -Proto 'UDP') -eq 'HTTPS/QUIC?') 'UDP 443 = HTTPS/QUIC?（如实标注不可分）'
Assert ((Get-NetServiceName -Port 53) -eq 'DNS') '53 = DNS'
Assert ((Get-NetServiceName -Port 99999) -eq '') '未知端口返回空串'
Assert ((Get-NetServiceName -Port 0) -eq '') '0 端口返回空串'

# 7. 大数不丢精度
$r7 = Get-NetProcessEventStats -Rows @(@{ pid = 1000; dir = 'recv'; size = 1073741824 }) -GamePid 1000
Assert ($r7.game.recv -eq 1073741824) '1 GiB 单行聚合正确' ("实际 " + $r7.game.recv)

Write-Host ''
if ($fail -eq 0) { Write-Host "== net-rules 全部通过（$pass 项）==" -ForegroundColor Green } else { Write-Host "== 失败 $fail 项 ==" -ForegroundColor Red; exit 1 }
