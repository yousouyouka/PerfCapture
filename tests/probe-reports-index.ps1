# 历史报告库探针（2.1.13 / F1）
#
# 只验证 62-Reports.ps1 里可独立调用的函数：索引、路径校验、伴随文件、删除。
# 不启动界面、不碰真实 reports 目录 —— 全部在临时目录里造数据。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-reports-index.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$mod = Join-Path $root 'src\app\62-Reports.ps1'

$script:fail = 0
$script:pass = 0
function Assert($cond, $name, $detail) {
    if ($cond) { $script:pass++; Write-Host ('  OK   ' + $name) -ForegroundColor DarkGray }
    else { $script:fail++; Write-Host ('  FAIL ' + $name + '  ' + $detail) -ForegroundColor Red }
}
# 模块会调 Write-AppLog；探针里给个空实现，避免依赖宿主
function Write-AppLog([string]$t, [string]$c = '') { }

if (-not (Test-Path -LiteralPath $mod)) { Write-Host '缺少 62-Reports.ps1' -ForegroundColor Red; exit 1 }
. $mod

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('pc-rep-probe-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function Write-Utf8([string]$path, [string]$text) {
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($true)))
}

$modern = @'
{ "schema_version": 3, "run": "20261123_101500_game", "process": "GameA",
  "captured_seconds": 120.0, "frames": 7200, "avg_fps": 120.4, "fps_1pct_low": 88.1,
  "resolution": "2560x1440",
  "environment": { "gpu_model": "NVIDIA GeForce RTX 5060", "driver_version": "566.36",
                   "os_version": "Microsoft Windows 11 专业版", "bios_version": "UHCN09WW / 2024-05-06" },
  "quality": { "level": "ok", "checks": [] } }
'@
$old = @'
{ "schema_version": 2, "run": "20261120_090000_game", "process": "GameA",
  "captured_seconds": 90.0, "frames": 5400, "avg_fps": 98.0, "fps_1pct_low": 70.2,
  "environment": { "gpu_model": "NVIDIA GeForce RTX 5060" } }
'@

Write-Utf8 (Join-Path $tmp '20261123_101500_game.json') $modern
Write-Utf8 (Join-Path $tmp '20261120_090000_game.json') $old
Write-Utf8 (Join-Path $tmp 'broken.json') '{ "schema_version": 3, "run": '
Write-Utf8 (Join-Path $tmp '20261123_101500_game.html') '<html>report</html>'
'TimeMs,msBetweenPresents
0,8.3
8.3,8.3
' | Out-File -FilePath (Join-Path $tmp '20261123_101500_game.presentmon.csv') -Encoding ASCII

# 控制时间顺序：modern 比 old 新
(Get-Item (Join-Path $tmp '20261120_090000_game.json')).LastWriteTime = [datetime]'2026-11-20 09:00:00'
(Get-Item (Join-Path $tmp '20261123_101500_game.json')).LastWriteTime = [datetime]'2026-11-23 10:15:00'

Write-Host '== 1. 索引：解析成功的进列表，坏文件不进 ==' -ForegroundColor Cyan
$idx = Get-ReportIndex -Dir $tmp -Fresh
Assert (@($idx.items).Count -eq 2) '两条记录（坏 JSON 被跳过）' ('实际 ' + @($idx.items).Count)
Assert ([int]$idx.total -eq 3) 'total 统计到 3 个 json（含坏文件）' ('实际 ' + $idx.total)
Assert ($idx.items[0].id -eq '20261123_101500_game') '按修改时间倒序（最新在前）' ('实际 ' + $idx.items[0].id)

Write-Host '== 2. 新旧 schema 字段兼容 ==' -ForegroundColor Cyan
$m = @($idx.items | Where-Object { $_.id -eq '20261123_101500_game' })[0]
$o = @($idx.items | Where-Object { $_.id -eq '20261120_090000_game' })[0]
Assert ($m.driver -eq '566.36') '新报告读到驱动版本' ('实际 ' + $m.driver)
Assert ($m.quality -eq 'ok') '新报告读到可信度' ('实际 ' + $m.quality)
Assert ($null -eq $o.driver -or $o.driver -eq '') '老报告缺驱动时为 null/空（不冒充）' ('实际 [' + $o.driver + ']')
Assert ($null -eq $o.quality -or $o.quality -eq '') '老报告缺 quality 时为 null/空' ('实际 [' + $o.quality + ']')
Assert ($null -ne $m.mtime -and [int64]$m.mtime -gt 0) 'mtime 是毫秒时间戳' ('实际 ' + $m.mtime)

Write-Host '== 3. 路径校验（防穿越 / 防任意后缀）==' -ForegroundColor Cyan
Assert ((Test-ReportId '20261123_101500_game')) '正常 id 通过'
Assert (-not (Test-ReportId '../evil')) '拒绝 .. 前缀'
Assert (-not (Test-ReportId 'a\b')) '拒绝反斜杠'
Assert (-not (Test-ReportId 'C:/Windows/win.ini')) '拒绝带盘符路径'
Assert (-not (Test-ReportId '..')) '拒绝纯点点'
Assert ($null -eq (Resolve-ReportFile '../../windows/win' $tmp)) 'Resolve 拒绝穿越'
Assert ($null -eq (Resolve-ReportFile '20261123_101500_game' $tmp '.exe')) 'Resolve 拒绝非白名单后缀'
Assert ($null -ne (Resolve-ReportFile '20261123_101500_game' $tmp '.json')) 'Resolve 正常 json'
Assert ($null -ne (Resolve-ReportFile '20261123_101500_game' $tmp '.presentmon.csv')) 'Resolve 识别逐帧 CSV 后缀'

Write-Host '== 4. 伴随文件清单 ==' -ForegroundColor Cyan
$files = @(Get-ReportFiles '20261123_101500_game' -Dir $tmp)
$kinds = @($files | ForEach-Object { $_.kind })
Assert ($kinds -contains 'json') '含 json'
Assert ($kinds -contains 'html') '含 html'
Assert ($kinds -contains 'pmcsv') '含逐帧 csv'
Assert (-not ($kinds -contains 'senscsv')) '没有传感器 csv 时不出该按钮'

Write-Host '== 5. 删除：默认带伴随文件，删完不再出现在索引 ==' -ForegroundColor Cyan
$removed = @(Remove-ReportFiles '20261123_101500_game' -Dir $tmp -WithAssets -Permanent)
Assert ($removed.Count -eq 3) '删除 3 个文件（json/html/csv）' ('实际 ' + $removed.Count)
Assert (-not (Test-Path (Join-Path $tmp '20261123_101500_game.json'))) 'json 已删除'
Assert (-not (Test-Path (Join-Path $tmp '20261123_101500_game.html'))) 'html 已删除'
$idx2 = Get-ReportIndex -Dir $tmp -Fresh
Assert (@($idx2.items).Count -eq 1) '索引只剩一条' ('实际 ' + @($idx2.items).Count)
Assert (@($idx2.items)[0].id -eq '20261120_090000_game') '剩下的是另一条' (@($idx2.items)[0].id)

Write-Host '== 6. 删除不存在的报告：安静返回空，不抛异常 ==' -ForegroundColor Cyan
$none = @(Remove-ReportFiles 'no_such_report' -Dir $tmp -Permanent)
Assert ($none.Count -eq 0) '返回空列表' ('实际 ' + $none.Count)

# 清理临时目录（探针自己造的数据，直接删）
try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }

Write-Host ''
if ($script:fail -gt 0) {
    Write-Host ('== 失败 ' + $script:fail + ' 项 / 通过 ' + $script:pass + ' 项 ==') -ForegroundColor Red
    exit 1
}
Write-Host ('== 通过 ' + $script:pass + ' 项 ==') -ForegroundColor Green
exit 0
