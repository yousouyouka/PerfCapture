# 实时 FPS 不显示的排查证据链（1.5.5 → 1.5.7）

> 记录时间：2026-11-16　机型：Lenovo Legion R9000P ADR10M / RTX 5060 Laptop / Win11 26200.9974
> 状态：**根因已定位，但尚未修复**（修复方案见最后一节）。验收时实时监控页与浮窗的 FPS 仍显示「—」。
> 本文所有结论都来自本机实测，不是推测；命令与返回都记在下面，便于复现。

## 0. 一句话结论

`边采边读 PresentMon 的输出` 这个设计在 PresentMon 2.6 上**不成立**：
它用 `--output_file` 时以**独占**方式持有 CSV（`FileShare.None`），跨进程读不到；
换成 `--output_stdout` 又是**块缓冲**，短时间内根本读不到行。
真正的修法是「短窗口采集 + 进程退出后解析」（见 §5）。

## 1. 第一层：程序没有管理员权限（已修）

**现象**：1.5.5 日志里

```
18:23:28.240 [WARN] 实时 FPS 不可用：presentmon exited early (exit code 6)
```

**取证**：检查运行中的宿主进程是否提权（OpenProcessToken + TokenElevation）：

```
pid=36152 elevated=0     ← 宿主没有管理员权限
```

**原因**：PresentMon 建 ETW 会话需要管理员（`logman`/ETW 权限）。未提权时它直接以退出码 6 退出，
所以后面所有目标都只能是「—」。

**修复（1.5.6 起）**：新增 `build\app.manifest`（`requireAdministrator` + `PerMonitorV2`），
`build\pack.ps1` 编译启动器时用 `csc /win32manifest:` 嵌入。
验证：`dist\PerfCapture-1.5.6\PerfCapture.exe` 字节里含 `requireAdministrator`、不含 `asInvoker`。

## 2. 第二层：残留 ETW 会话把 DxgKrnl 堵死（已加清场）

**现象**：提权后仍 0 行。抓 stderr：

```
error: failed to start trace session: error code 4201.
```

另外用默认会话名时：

```
error: a trace session named "PresentMon" is already running.
```

**原因**：`Stop-Process` 杀掉 presentmon 不会移除它的 ETW 会话；卡死的会话会占着 DxgKrnl 提供程序，
后续任何采集（哪怕换进程、换会话名）都收不到 present 事件。

**对照实验**（提权，目标 Endfield，8 秒）：

```
# 清场前：0 行
# 清场（logman stop PresentMon / PerfCaptureLive_*）后：
default-name: exit=running rows=1661     ← 8 秒 1661 行，≈207 FPS
tempRootWithRedir:   rows=1250
tempPerfDirWithRedir: rows=1286
tempPerfDirNoRedir:  rows=1334
```

→ 链路本身完全可用，只是被残留会话挡住。

**修复（1.5.7）**：采样器开采集前 `Get-Process presentmon | Stop-Process`，
并用**绝对路径** `%SystemRoot%\System32\logman.exe` 停掉 `PerfCaptureLive*` / `PresentMon*` 会话
（runspace 里 `logman` 走 PATH 不可靠，实测要用绝对路径）。

## 3. 第三层：`--output_file` 是独占打开（**真正的拦路虎**）

**现象**：即使提权 + 清场，采样器仍计 0 行，但 CSV 文件在长：

```
err: 目标 Endfield(pid 16292) 连续 6 秒无帧
     （csv=164765，提权=True，ok=True，framesSeen=0，
      读错=read: 使用"4"个参数调用"Open"时发生异常:
      "文件"…\PerfCapture\b62_live.csv"正由另一进程使用，因此该进程无法访问此文件。"）
```

**原因**：PresentMon 以 `FileShare.None` 打开输出文件；我们三种共享模式都试过，全部被拒：

```powershell
[IO.File]::Open($path,'Open','Read',[IO.FileShare]::ReadWrite)                 # 失败
[IO.File]::Open($path,'Open','Read',[IO.FileShare]::ReadWrite -bor ::Delete)    # 失败
[IO.File]::Open($path,'Open','Read',[IO.FileShare]::Read)                       # 失败
```

**结论**：只要 PresentMon 还在写，任何其它进程都读不到这个文件。实时读文件这条路封死。

## 4. 第四层：`--output_stdout` 是块缓冲（替代方案也不通）

**尝试**：`--output_stdout --no_csv` + `Start-Process -RedirectStandardOutput <file>`
（文件句柄归本进程，理论上不再有跨进程锁）。

**结果**：句柄确实可读（`readable=yes`），但**8 秒只落 2 字节**——stdout 非终端时是块缓冲，
PresentMon 不会逐帧 flush。

→ 这个方向同样拿不到实时数据。

## 5. 正确修法（待实现）：短窗口采集 + 退出后解析

不再「边采边读」，改成**分段采集**：

1. 每约 3 秒起一次 PresentMon：`--timed 3 --terminate_after_timed --session_name PerfCaptureLive_<随机>`
2. 等它**自己退出**（此时文件锁释放、会话也自动结束）
3. 读 CSV 数帧 → FPS = 行数 / 3；顺带能算 1% Low（帧时间列）、帧时间、显示延迟等
4. 代价：FPS 刷新粒度从 1 秒变成约 3 秒；对「看个大概帧率」够用，且不再有独占锁与残留会话两个坑

同一个思路也能把 P1 指标（1% Low / 帧时间 / 显示延迟 / GPU 延迟）一起带出来，因为退出后可以完整解析 CSV。

## 6. 其它已验证但不构成原因的项

| 检查 | 结果 |
|---|---|
| ETW 本身是否可用（`logman create trace -p Microsoft-Windows-DxgKrnl`，5 秒） | 正常，ETL **108 MB** |
| PresentMon 版本 | 随包 = winget = **2.6.0**（GitHub 最新稳定版也是 2.6.0，没有 2.7/2.8 可升） |
| 官方采集引擎 `Measure-GamePerf.ps1`（提权、会清场） | 有时也报 `PresentMon did not capture anything.`，与 §2 的会话脏污一致 |
| NVIDIA Overlay / NVTOPPS 会话 | 停掉后无改善，不是原因 |
| 目标窗口前台状态 | 已用 `SetForegroundWindow` 固定 Endfield，GPU 99% 正在出帧，仍 0 行 |
| 输出目录（`%TEMP%` vs `%TEMP%\PerfCapture`） | 两者都能写，不是原因 |
| 是否加 `-RedirectStandardError` | 与能否出帧无关 |

## 7. 现场清理建议

排查过程反复启停 PresentMon，机器上的 ETW 会话可能已被搞脏。**重启一次**最稳妥；
不重启的话，可手动执行（管理员）：

```
logman stop PresentMon -ets
logman query -ets | findstr /i "PerfCapture PresentMon"
```

（有残留就按名字 `logman stop <名字> -ets`；本项目自己的会话名形如 `PerfCaptureLive_xxxxxxxx`。）

## 8. 附：本轮相关提交

- `0a00f96` 1.5.4 顶部板块 + 浮窗设置 + FPS 跟随前台
- `ae91369` 1.5.5 拖动回填、目标不再乱跳、无帧诊断
- `23da87f` 1.5.7 提权（app.manifest）、ETW 清场、诊断字段补全

---

## 9. 结论落地：改用 burst 模式（1.5.10）

### 9.1 做法
每轮起一个短窗口，**等 PresentMon 自己退出、文件锁释放后再整份解析**：

```
presentmon --process_id <pid> --output_file <burst.csv> \
           --timed 2 --terminate_after_timed \
           --v2_metrics --no_console_stats \
           --session_name PerfCaptureLive_<8位> --stop_existing_session
```

- `FPS = 帧数 ÷ (末帧起点 − 首帧起点 + 末帧自身时长)`
  —— 少算末帧会系统性抬高一档（60 帧 @16.67ms 会算成 61），已校正。
- 读数 = 最近 3 个窗口按帧数加权；窗口间歇期沿用上一次值，连续 4 个空窗口才清空。
- 失败退避：退出码 6（未提权）15 s、其它非 0 退出 10 s、连续空窗口 3 s。
- 日志去重：同一错误只记一次，未恢复每 2 分钟提醒，恢复时记「已恢复」。

### 9.2 本机实测（2026-11-16，重启后，提权）
| 项 | 值 |
|---|---|
| 目标 | WebView2 的 GPU 进程（Chromium，走 D3D11 present），240 Hz 窗口动画 |
| burst 退出码 | 0 |
| CSV 大小 | 34,946 字节 |
| 帧数 | **239** |
| 窗口时长 | 0.998 s |
| **FPS** | **239.49**（与 240 Hz 刷新率一致） |
| P95 帧时间 | 4.45 ms |
| 对照组（不指定进程） | 906 帧；帧最多的应用：PI-Desktop.exe 475 / msedgewebview2.exe 431 |

> 说明：`--timed 2` 里实际落盘约 1 s 的帧（ETW 会话建立要占掉开头一段），所以窗口有效期按
> 实际 `CPUStartTime` 跨度算，不按请求时长算。

### 9.3 仍然成立的两条铁律
1. **不要边采边读**：`--output_file` 独占、`--output_stdout` 块缓冲，两条路都不通。
2. **ETW 会话要清场**：被杀掉的 PresentMon 会留下卡死会话，第一次启动前 `logman stop` 自家前缀。