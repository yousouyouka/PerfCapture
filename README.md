# PerfCapture

Windows 游戏性能采集工具：用 PresentMon 的 ETW 事件统计帧，**默认零注入**（不注入 DLL、不挂覆盖层），
不会触发反作弊或显卡驱动的注入检测 —— 因此不会因为本工具关掉 DLSS。
是否引入可能注入的能力由你决定：这类能力会以可选扩展的形式提供，默认不装、需要才装，而不是替你做主。

## 采集内容

平均帧率 / 1% Low（丢最差一帧后取 1%）/ 最大帧率、帧时间 p95、上屏延迟（DisplayLatency）、PC 延迟、
GPU 占用与温度、显存与内存、图显特性（后端 / DLSS·FSR·XeSS / 档位 / 分辨率 / 窗口模式）。
报告带阈值判定（正常 / 略高 / 偏高），支持浅色与深色主题。

## 运行要求

- Windows 10 1809+ / 11（x64）；管理员权限（ETW 会话），首次启动弹一次 UAC
- 不需要安装 .NET、不需要 winget 装 PresentMon（`tools\` 内置）
- WebView2 用系统自带运行时（缺则程序给安装引导；要彻底离线可内置到 `runtime\webview2\`）
- GPU 指标依赖 `nvidia-smi`（驱动自带）；缺失时显示 `—`，不影响帧率与延迟

## 使用

双击 `PerfCapture.exe` → 选「目标进程」→ 设采集秒数（默认 120）→ 点「开始采集」
（倒计时 5 秒并最小化，采集期间保持游戏在前台）→ 结束后右侧直接出报告 →「导出报告」/「导出长图」。

## 扩展中心

默认状态仍是零注入：不装任何扩展时，本工具不注入游戏、不触发反作弊、不会关掉 DLSS。
更高频的帧率刷新等能力通过侧边栏「扩展中心」以**可选扩展**提供；首个可用扩展是 RTSS 共享内存数据源。

RTSS 扩展点「一键启用」即可：软件内静默下载固定版本的官方安装包（不随程序携带、不打开第三方网页），
校验 SHA-256 与签名后静默安装到用户目录、自动配置并启动自有副本；安装时仅弹一次系统确认。
本机原先已安装的 RTSS 会被无视，不会被复用或结束。所有已启用扩展在下次打开 PerfCapture 时自动恢复，但不设置 Windows 开机自启。

每个扩展都可**随时一键关闭，关闭后立即消除它的影响，无需卸载**：本软件安装的 RTSS 副本会被结束，
数据源回退到零注入基线。RTSS 帧数据强大、对绝大多数游戏正常工作，但如果你发现某个游戏因此关闭了 DLSS，
关掉该扩展即可恢复，不必卸载。极少数游戏可能与注入型扩展不兼容；遇到时以关闭扩展应对即可。

1. 运行 `dist\PerfCapture-Setup-<版本>.exe`（单文件，约 10 MB，内嵌全部程序文件）。
2. 五页向导：欢迎 → 选择目标位置 → 选择附加任务 → 正在安装（可取消并回滚）→ 完成。
3. 默认按用户装到 `%LOCALAPPDATA%\Programs\PerfCapture`，**安装不需要管理员**（采集时才提权）；
   装到 `C:\Program Files` 需以管理员身份运行安装程序。
4. 卸载用「设置 → 应用」或安装目录里的 `uninstall.exe`，**不删除**配置与历史报告。

```
PerfCapture-Setup-<版本>.exe /S /D=D:\Apps\PerfCapture      # 静默安装
PerfCapture-Setup-<版本>.exe /S /NODESKTOP /NOMENU /NORUN    # 静默安装，不建快捷方式、不自动启动
"D:\Apps\PerfCapture\uninstall.exe" /U /S                    # 静默卸载
```

绿色包：解压 `dist\PerfCapture-<版本>.zip`，双击 `PerfCapture.exe`。

## 数据位置

| 内容 | 位置 |
|---|---|
| 程序 | `%LOCALAPPDATA%\Programs\PerfCapture` |
| 配置 / 日志 / 报告 | `%LOCALAPPDATA%\PerfCapture`（`PerfCapture.settings.json`、`reports\`） |

## 开发

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File src\PerfCapture.ps1   # 直接跑（弹 UAC）
powershell -NoProfile -ExecutionPolicy Bypass -File build\pack.ps1        # 打包：目录 + zip + 安装包
powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1       # 冒烟（源与 dist 各跑一次）
```

架构：`PerfCapture.exe` → `src\PerfCapture.ps1` 按序 dot-source `src\app\*`（宿主）→ WebView2 渲染 `ui\`；
采集在 `src\engine\Measure-GamePerf.ps1`，可独立单跑。目录树与完整约定见 `AGENTS.md`。

硬规则：

- 含中文的 `.ps1` 必须 UTF-8 **with BOM**；`src\app\*` 不用 `$PSScriptRoot`，顶层不用 `return`
- **默认零注入**：基础发行版不加注入型覆盖层，不打包 RTSS 安装包；要更强能力走「扩展中心」，由用户 opt-in 一键启用，
  软件内静默下载安装、不设开机自启，且每个扩展都可随时一键关闭、关闭即消除影响（无需卸载）
- DPI 只换算一次：字号用 pt、`AutoScaleMode=None`、exe 编入 `build\setup-dpi.manifest`
- 发版同步四处：`VERSION`、`ui\index.html` 两处、`CHANGELOG.md`、`ui\js\updates-data.js`

分批推进，一批一个版本号；变更历史见 `CHANGELOG.md`，回滚用该批之前的 `dist\` 目录。

## 依赖

WebView2 运行时（系统自带，可内置到 `runtime\webview2\` 彻底离线）、`lib\` 的 WebView2 .NET 组件、
`tools\presentmon.exe`（MIT，可再分发）、`assets\` 的字体与背景。声明在 `deps\deps.json`。
