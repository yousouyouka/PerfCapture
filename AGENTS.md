# AGENTS.md

本仓库工作指南。改代码前读「硬约束」与「边界」，改完按「验证」自证，别交"看起来能用"的东西。

## 项目

Windows 游戏性能采集工具：**零注入**（PresentMon ETW，不注入 DLL、不挂覆盖层），因此不触发反作弊
与 DLSS 驱动门禁；单机可用（只依赖系统 WebView2 + 可选 `nvidia-smi`）。

```
PerfCapture.exe(launcher.cs) → src\PerfCapture.ps1 → 按序 dot-source src\app\*
   00-Prelude(DPI/程序集) 05-Paths 10-Bootstrap(提权→单实例→依赖) 15-Logging 20-Settings
   30-Tools 40-Bridge 50-Host(窗口+WebView2) 60-Capture(采集/导出) 90-Main(主循环)
   └ src\engine\Measure-GamePerf.ps1   采集引擎（可单跑）
```

主界面是 `ShowDialog` 模态窗口。桥接：ui→host `ready|refreshProcs|saveSettings|openReports|export|exportHtml|exportPng|start|stop`；
host→ui `init|procs|status|progress|log|report|busy|theme|exportable|pngDone|error`。

## 目录

```
src/app\        宿主（编号递增；新逻辑进对应文件，必要时在入口登记）
src/engine\     采集引擎
ui\             index.html + css(tokens/layout/components/terminal/report/updates/survey) + js(无 ES module；页面数据放 *-data.js)
assets\ lib\ tools\ runtime\webview2(可选)  deps\ deps-inbox\  tests\  build\  dist\  reports\(不打包)
build\          pack.ps1 · launcher.cs · setup-core.cs · setup-ui.cs · setup-dpi.manifest
```

## 硬约束（违反即坏）

1. **零注入**：不加任何注入型覆盖层，不打包 RTSS。
2. 含中文的 `.ps1` 必须 **UTF-8 with BOM**；Write 类工具写完必须补：
   `[IO.File]::WriteAllText($p,$t,(New-Object Text.UTF8Encoding($true)))`
3. **DPI 只换算一次**：进程已 PerMonitorV2 感知 → 字号只用 pt（不再乘 `DpiScale`）、
   WinForms 窗体 `AutoScaleMode=None` + 手工 scale、独立 exe 必须 `/win32manifest:build\setup-dpi.manifest`。
4. UI 字体只用 `assets\方正兰亭圆_GBK_中粗.ttf`，`font-weight` 只用 400；排版可学 TextAxis，字体配色不搬。
5. 不做两套发行版；WebView2 依赖系统，只有用户自己放 `runtime\webview2\` 才内置。
6. 用户数据在 `%LOCALAPPDATA%\PerfCapture`，装在 `%LOCALAPPDATA%\Programs\PerfCapture`；卸载不删数据。
7. `reports\` 绝不打进产物；采集验证统一 30 秒。

## 风格

- PowerShell `动词-名词`；**dot-source 三条铁律**：子文件不用 `$PSScriptRoot`（用 `$script:Root`）、
  提权重启用 `$script:EntryPath`、顶层不用 `return`（用 `exit`）。
- C# 只用 C# 5 语法（无插值 / `?.` / `nameof`），依赖仅 System.Windows.Forms / Drawing / IO.Compression。
- JS 不用 ES module，`<script>` 顺序加载；文案走 `ui/js/i18n.js`（zh-CN / en-US / ja-JP），不写死中文。
- CSS 走 `tokens.css` 变量，两套主题同时成立；滚动条自绘（8px / 圆角 4px），不显示系统滚动条。

## 样式与版式（改 UI 的硬要求）

- **只认 tokens**：颜色、圆角、阴影、间距一律用 `ui/css/tokens.css` 的变量，组件里不写死色值；
  亮/暗两套主题必须同时成立（`data-theme`），不接受"只在一种主题下好看"。
- **字体**：`assets\方正兰亭圆_GBK_中粗.ttf`，`font-weight` 只用 **400**（该字面没有粗体）。
- **字号**（rem，基准 16px）：页标题 1.05、条目/卡片标题 0.95–1、正文 0.74–0.76、
  辅助说明 0.66–0.69、小标签与徽标 0.62–0.66。
- **圆角**：大卡片 14px、内容卡片 12px、按钮与筛选 chip 8px、药丸与徽标 99px、小标签 4–5px；
  滚动条自绘 **8px 宽 / 4px 圆角**，不出现系统滚动条。
- **卡片**：`background: var(--card)` + `1px solid var(--line)` + `box-shadow: var(--shadow)`；
  hover 换成 `--line-strong` + `--shadow-hover`；强调只用 `--accent` / `--accent-soft`。
- **空状态**：`var(--tile)` 底 + `1px dashed var(--line-strong)` + 居中，主文用 muted、副文用 faint
  （问卷页与实时监控页是样板）。
- **板块节奏**照 TextAxis（页头 / 工具栏 / 主区 / 列表），**字体与配色不搬**；图标用内联 SVG stroke，
  不引图标字体、不引第三方 UI 库。
- 新页面/新板块的样式写进自己的 css 并在 `index.html` 按顺序加载；并列的工具行可以共用一组选择器
  （见 `updates.css` 的 `.updates-areas, .updates-filters`）。

## 发布决策（硬规则）

- **是否发布由用户决定**。新版本一旦对外（tag、GitHub Release、`updates` 分支、`latest.json`、镜像同步），
  就再也收不回来 —— 所以这些动作**必须先得到用户明确同意**。
- **内容已改好 ≠ 要发布**。仓库里攒了新版本、`updates\*.json` 与签名都生成好了、冒烟也全过，
  **都不构成发布理由**；每一版都要**用户单独点头**，一次同意只对那一版有效，不能沿用上一次。
- 准备就绪后智能体应当**停下来问**：「是否发布 vX.Y.Z？」，并列出待执行动作
  （打 tag / 发 Release / push `updates` 分支 / 推送清单），等用户答复再动。
- 智能体只负责：跑冒烟与打包、生成 `updates\*.json` 与签名、准备好待执行的命令；
  **不自行 push tag、不自行发 Release、不自行推 `updates` 分支**。
- 检查更新的自动行为：**每次启动最多检查一次**；没发现新版本就**停止本次会话的自动检查**
  （下次启动恢复）；发现新版本提示后同样不再重复检查，直到用户操作或重启。

## 版本号规则（务必照做）

`主.次.修补` 三段分别是什么、谁能动：

| 位 | 何时 +1 | 谁决定 |
|---|---|---|
| 主（数字 1） | 只有**大更新**才动 | **用户通知**，智能体不自行改 |
| 次（数字 2） | 加入**小型新功能**之后 | **用户通知**，智能体不自行改 |
| 修补（数字 3） | **每轮对话 +1**（修订、优化、补文档等不引入新内容的工作） | 智能体自动 +1 |

- **默认只动第三位**。前两位没有用户明确通知就保持不动，哪怕这轮确实加了功能。
- 三段都是十进制数字：`1.3.10` 合法且大于 `1.3.9`（不是 1.3.1.0）。
- 更新公告右侧的版本线只显示「主.次」，所以只有用户升第二位时才会多出一条线。
- 发版四处同步（冒烟钉住）：`VERSION`、`ui\index.html` 两处、`CHANGELOG.md` 顶部新段、
  `ui\js\updates-data.js` 数组最前一条 + `PerfUpdateVersions`。
- 反面教训：1.4.0 / 1.4.1 是智能体擅自升了第二位，已按本条合并回 **1.3 线**
  （1.3.8 / 1.3.9 / 1.3.10），别再犯。

## 仓库与交付（GitHub）

- `.gitignore` 已排除 `dist\`、`reports\`、`PerfCapture.settings.json`、`build\payload.zip`、日志与临时文件；
  **产物与个人数据不进仓库**。
- 二进制随仓库：`lib\`（WebView2 .NET 组件）、`tools\presentmon.exe`（MIT）、`assets\`（字体/图标）；
  替换时留意许可，并同步 `deps\deps.json` 的说明。
- 提交前跑 `tests\smoke.ps1` 与 `build\pack.ps1`（打包脚本的绝对路径审计会拦住个人路径泄漏）。
- 版本标签用 `v<完整版本号>`（如 `v1.3.10`），与 `VERSION` 文件一致。
- 检查更新的发布链路：`build\pack.ps1` 生成 `updates\*.json` 与签名 → `build\push-updates.ps1`
  把安装包与清单推到 **`updates` 分支**（jsDelivr / raw 都从这条分支取）→ 需要 Release 时再 `gh release create`。
  `push-updates.ps1` **不带 `-Yes` 只打印计划**，分支上只留最近 2 个版本的资产。
- `updates` 分支里的清单要 `.gitattributes: * -text`（关闭换行转换）：签名按**字节**算，
  LF→CRLF 会让验签失败；脚本提交前会自证分支 blob 字节与本地一致。
- **jsDelivr 不发 `.exe`**（实测 403 Forbidden，`.zip` 与 `.json` 正常 200）：清单里 `.exe` 的
  下载源必须从 `raw.githubusercontent.com` 起排，`pack.ps1` 已按类型生成，冒烟也钉住了。
- **推完必须整分支 purge jsDelivr**（`https://purge.jsdelivr.net/gh/<owner>/<repo>@main` 与 `@updates`）：
  只清单个文件会留下「清单已换新、`.sig` 还是旧」的错配，客户端验签必失败；
  `raw.githubusercontent.com` 另有约 3~5 分钟缓存，发布后立刻验证要等它过期。

## 边界

- 不做注入方案、读写游戏内存、自动装驱动级组件；实时监控目前只是入口占位。
- 不在没要求时动无关区域，不"顺手重构"。
- 不做自动点击 / 键鼠模拟的测试；安装向导点击流程由人走查。

## 验证

1. `tests\smoke.ps1` **源与 dist 各跑一次**，全绿。
2. `build\pack.ps1`：必需文件、绝对路径审计、体积都要过。
3. UI 改动用真 WebView2 探针（offscreen 表单 + `CreateAsync`）跑断言；CDP 必须泵消息等待
   （`while(-not $t.IsCompleted){DoEvents(); Sleep 25}`），**不能 `.Result`**。
4. 导出长图 / 提示窗 / 安装向导这类"看起来能用"的，必须回读像素与尺寸自证（1px 探针线是否仍占 1 列、
   文字是否溢出、颜色是否落在 tokens 里）。

## 回滚

按批次回滚（一批一个版本号，锚点 1.1）：

1. 程序：换回 `dist\PerfCapture-<上一版>\`，或跑上一版安装包覆盖安装。
2. 卸载：`uninstall.exe /U /S` 只删程序与快捷方式，不动 `%LOCALAPPDATA%\PerfCapture`。
3. 数据：配置只做**补缺迁移**（不覆盖用户值），降级不用改数据；要清空就删配置文件与 `reports\`。
4. 代码：按批次文件清单回退，`VERSION` / `CHANGELOG.md` / `updates-data.js` 一起退。回滚后重跑冒烟与探针。

## 坑

- `$env:TEMP` 可能是 8.3 短名（`YOUSOU~1`），路径比较前用 `[IO.Path]::GetFullPath()` 归一。
- PowerShell 单引号多行字符串里出现 `'` 会提前终止（`.querySelector('.x')` 改双引号）。
- **CDP 不能在 `WebMessageReceived` 回调里调**（必超时）→ `Queue-Export` + `Form.BeginInvoke`。
- 主界面是模态：`Visible=false`（`Hide()`/`SW_HIDE`）会让主循环结束、程序退出；最小化会让 CDP 挂住。
  藏窗口**只能用 `Opacity = 0`**。
- `ZipFile` 目录项可能用反斜杠，判断目录要 `entry.FullName.Replace('\\','/')`。
- 单实例：**先提权再抢锁**；`AbandonedMutexException` 的语义是"锁归你"，必须当作拿到。
- 导出长图的图表位图取**原 canvas**（`cloneNode` 不带位图）；拖动分割用按下时的尺寸做基准。
