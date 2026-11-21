# B135 浮窗拖动锁探针（2.1.7）：overlay.locked 的默认值、类型归一、应用与回传。
# 不建窗体（不弹窗、不碰桌面）：只驱动配置层与消息层，窗体处理器用源码契约守卫。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-b135-overlay-lock.ps1

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Ok([string]$m) { Write-Host "  ✅ $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  ❌ $m" -ForegroundColor Red; $script:fail++ }
function Assert([bool]$cond, [string]$ok, [string]$bad) { if ($cond) { Ok $ok } else { Bad $bad } }

Write-Host '== B135 浮窗拖动锁探针 ==' -ForegroundColor Cyan

# ---------- stub 宿主依赖 ----------
$script:Root = $root
$script:UiMessages = New-Object System.Collections.ArrayList
function Write-AppLog([string]$text, [string]$lvl = 'INFO') { }
function Send-ToUi([hashtable]$payload) { [void]$script:UiMessages.Add($payload) }
function Save-Config { $script:SaveCount++ }
$script:SaveCount = 0
$script:Cfg = @{ overlay = @{} }

. (Join-Path $root 'src\app\55-Overlay.ps1')

# ---------- 1. 默认不锁 ----------
$cfg = Get-OverlayCfg
Assert ($cfg.locked -eq $false) '默认不锁拖动（老配置升级后行为不变）' "默认值不是 false：$($cfg.locked)"

# ---------- 2. 类型归一：JSON 里可能写成字符串/数字 ----------
$script:Cfg.overlay = @{ locked = 'true' }
Assert ((Get-OverlayCfg).locked -eq $true) '字符串 "true" 归一为锁定' '字符串 true 没被识别'
$script:Cfg.overlay = @{ locked = '1' }
Assert ((Get-OverlayCfg).locked -eq $true) '字符串 "1" 归一为锁定' '字符串 1 没被识别'
$script:Cfg.overlay = @{ locked = 'false' }
Assert ((Get-OverlayCfg).locked -eq $false) '字符串 "false" 归一为不锁' '字符串 false 被误判为锁'
$script:Cfg.overlay = @{ locked = $true }
Assert ((Get-OverlayCfg).locked -eq $true) '布尔 true 保持锁定' '布尔 true 没被识别'

# ---------- 3. 前端下发：overlayConfig.locked 落盘 ----------
$script:Cfg.overlay = @{}
$script:SaveCount = 0
Apply-OverlayConfig ([pscustomobject]@{ locked = $true })
Assert ((Get-OverlayCfg).locked -eq $true) '前端下发 locked=true 后配置为锁定' '下发的 true 没生效'
Assert ($script:SaveCount -ge 1) '改动后立即落盘（不用等别的设置触发保存）' '改动没有落盘'
Apply-OverlayConfig ([pscustomobject]@{ locked = $false })
Assert ((Get-OverlayCfg).locked -eq $false) '前端下发 locked=false 后解除锁定' '下发的 false 没生效'

# 非法值不猜测：保持原状，不静默改成 true
$script:Cfg.overlay = @{ locked = $true }
Apply-OverlayConfig ([pscustomobject]@{ locked = 'maybe' })
Assert ((Get-OverlayCfg).locked -eq $true) '非法值被忽略、保持原状态（不擅自解锁）' '非法值把状态改坏了'

# ---------- 4. 状态回传：overlayState 带 locked ----------
$script:Cfg.overlay = @{ locked = $true }
$script:UiMessages.Clear()
Send-OverlayState
$msg = @($script:UiMessages | Where-Object { $_.type -eq 'overlayState' })
Assert ($msg.Count -eq 1) '回传了一条 overlayState' '没有回传 overlayState'
if ($msg.Count -eq 1) {
    Assert ($msg[0].overlay.locked -eq $true) 'overlayState.overlay.locked 如实回传' "回传缺少 locked：$($msg[0].overlay.locked)"
    Assert ($null -ne $msg[0].overlay.items) '其余字段未被破坏（items 仍在）' '回传结构被改坏'
}

# ---------- 5. 源码契约：窗体真的在拖动分支里判锁 ----------
$ovPs = Get-Content (Join-Path $root 'src\app\55-Overlay.ps1') -Raw -Encoding UTF8
$guard = [regex]::Matches($ovPs, 'if \(\$script:OverlayLocked\) \{ return \}')
Assert ($guard.Count -ge 1) "拖动处理器有锁判断（$($guard.Count) 处）" '拖动处理器没有判锁，勾了也照样能拖'
Assert ($ovPs -match '\$script:OverlayLocked = \[bool\]\$cfg\.locked') '建窗体时从配置读取锁状态' '建窗体时没读锁状态'
Assert ($ovPs -match 'Save-OverlayPosition') '拖动结束仍保存位置（未锁时）' '拖动结束逻辑缺失'
# 锁的是拖动，不是双击收起：显式操作不该被一起禁掉
Assert ($ovPs -match 'Toggle-OverlayCollapsed') '双击收起仍然保留' '锁拖动把双击收起也删了'

# 前端契约
$idx = Get-Content (Join-Path $root 'ui\index.html') -Raw -Encoding UTF8
Assert ($idx -match 'id="ovLockDrag"') '界面有 ovLockDrag 开关' '界面缺开关'
Assert ($idx -match 'realtime\.set\.dragLock') '开关文案走 i18n' '开关文案硬编码'
$rtJs = Get-Content (Join-Path $root 'ui\js\realtime.js') -Raw -Encoding UTF8
Assert ($rtJs -match 'locked: !!o\.locked') '前端从宿主状态回填 locked' '前端没回填 locked'
Assert ($rtJs -match 'cfg\.locked = !!lockDragEl\.checked') '勾选后写回 cfg.locked' '勾选没有写回配置'
$i18n = Get-Content (Join-Path $root 'ui\js\i18n.js') -Raw -Encoding UTF8
foreach ($k in 'realtime.set.dragLock', 'realtime.set.dragLockOff') {
    # 三语各一条
    $n = [regex]::Matches($i18n, [regex]::Escape("'" + $k + "'")).Count
    Assert ($n -eq 3) "i18n 三语齐全：$k（$n 条）" "i18n 缺 $k（只有 $n 条）"
}

if ($fail -gt 0) { Write-Host "== B135 失败 $fail 项 ==" -ForegroundColor Red; exit 1 }
Write-Host '== B135 通过 ==' -ForegroundColor Cyan
exit 0
