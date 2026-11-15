// PerfCapture 安装程序（csc 就地编译，零第三方依赖）
// 产物：PerfCapture-Setup-<版本>.exe，内嵌 payload.zip（= dist 目录内容）
// 命令行：
//   /S                       静默安装
//   /D=<路径>                 指定安装目录（静默/界面都能用）
//   /NODESKTOP /NOMENU /NORUN 静默安装时跳过对应动作
//   /U                       卸载（加 /S 则静默卸载）
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

namespace PerfCaptureSetup
{
    internal sealed class Options
    {
        public bool Silent;
        public bool Uninstall;
        public bool NoDesktop;
        public bool NoMenu;
        public bool NoRun;
        public bool RunAfterInstall;   // /RUN：静默装完后自动运行新版本（应用内更新走这条）
        public string Dir = "";
    }

    internal sealed class PayloadInfo
    {
        public string Version = "0.0.0";
        public long Bytes;
        public int Files;
    }

    internal static class Program
    {
        internal const string AppName = "PerfCapture";
        internal const string Publisher = "PerfCapture";
        internal const string PayloadName = "payload.zip";
        internal const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\PerfCapture";

        internal static string DefaultDir()
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(Path.Combine(local, "Programs"), AppName);
        }

        internal static string DataDir()
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(local, AppName);
        }

        internal static void Log(string text)
        {
            try
            {
                string path = Path.Combine(Path.GetTempPath(), "PerfCapture-setup.log");
                File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + text + Environment.NewLine, Encoding.UTF8);
            }
            catch { }
        }

        internal static Stream OpenPayload()
        {
            Assembly asm = Assembly.GetExecutingAssembly();
            Stream s = asm.GetManifestResourceStream(PayloadName);
            if (s != null) return s;
            foreach (string name in asm.GetManifestResourceNames())
            {
                if (name.EndsWith(PayloadName, StringComparison.OrdinalIgnoreCase))
                    return asm.GetManifestResourceStream(name);
            }
            throw new InvalidOperationException("安装包损坏：找不到内嵌的 payload.zip");
        }

        internal static PayloadInfo ReadPayloadInfo()
        {
            PayloadInfo info = new PayloadInfo();
            using (Stream s = OpenPayload())
            using (ZipArchive zip = new ZipArchive(s, ZipArchiveMode.Read))
            {
                foreach (ZipArchiveEntry e in zip.Entries)
                {
                    if (e.FullName.EndsWith("/", StringComparison.Ordinal)) continue;
                    info.Files++;
                    info.Bytes += e.Length;
                    if (string.Equals(e.FullName, "VERSION", StringComparison.OrdinalIgnoreCase))
                    {
                        using (StreamReader r = new StreamReader(e.Open(), Encoding.UTF8))
                            info.Version = r.ReadToEnd().Trim();
                    }
                }
            }
            return info;
        }

        private static bool IsUninstallerExe()
        {
            try
            {
                string name = Path.GetFileNameWithoutExtension(Application.ExecutablePath) ?? "";
                return name.StartsWith("uninstall", StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        private static Options ParseArgs(string[] argv)
        {
            Options o = new Options();
            foreach (string raw in argv)
            {
                string a = raw.Trim();
                if (a.Equals("/S", StringComparison.OrdinalIgnoreCase) || a.Equals("-S", StringComparison.OrdinalIgnoreCase)) o.Silent = true;
                else if (a.Equals("/U", StringComparison.OrdinalIgnoreCase) || a.Equals("-U", StringComparison.OrdinalIgnoreCase)) o.Uninstall = true;
                else if (a.Equals("/NODESKTOP", StringComparison.OrdinalIgnoreCase)) o.NoDesktop = true;
                else if (a.Equals("/NOMENU", StringComparison.OrdinalIgnoreCase)) o.NoMenu = true;
                else if (a.Equals("/NORUN", StringComparison.OrdinalIgnoreCase)) o.NoRun = true;
                else if (a.Equals("/RUN", StringComparison.OrdinalIgnoreCase)) o.RunAfterInstall = true;
                else if (a.StartsWith("/D=", StringComparison.OrdinalIgnoreCase)) o.Dir = a.Substring(3).Trim('\"');
                else if (a.StartsWith("-D=", StringComparison.OrdinalIgnoreCase)) o.Dir = a.Substring(3).Trim('"');
            }
            if (o.Dir.Length == 0) o.Dir = DefaultDir();
            return o;
        }

        [STAThread]
        internal static int Main(string[] argv)
        {
            Options opts = ParseArgs(argv);
            // 卸载程序是安装程序的副本，靠 /U 区分模式。用户双击 uninstall.exe 时没有任何参数，
            // 曾经因此走进「安装」分支（界面弹的是安装向导、点完什么都没删）。
            // 所以：进程名是 uninstall*.exe 且没显式要求安装时，一律按卸载处理。
            if (!opts.Uninstall && IsUninstallerExe()) opts.Uninstall = true;
            try
            {
                if (opts.Uninstall) return Uninstaller.Run(opts);
                PayloadInfo info = ReadPayloadInfo();
                if (opts.Silent)
                {
                    Installer.Result r = Installer.Run(opts, info, null, null);
                    // /RUN：静默更新装完直接运行新版本（不建快捷方式，见 /NODESKTOP /NOMENU）
                    if (r.Ok && opts.RunAfterInstall)
                    {
                        try
                        {
                            string exe = Path.Combine(r.Dir, Program.AppName + ".exe");
                            if (File.Exists(exe))
                            {
                                ProcessStartInfo psi = new ProcessStartInfo(exe);
                                psi.WorkingDirectory = r.Dir;
                                Process.Start(psi);
                            }
                        }
                        catch (Exception ex) { Program.Log("静默安装后启动失败：" + ex.Message); }
                    }
                    return r.Ok ? 0 : 1;
                }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                using (SetupForm f = new SetupForm(opts, info))
                {
                    Application.Run(f);
                    return f.ExitCode;
                }
            }
            catch (Exception ex)
            {
                Program.Log("Main 出错：" + ex.ToString());
                if (opts.Silent) return 2;
                MessageBox.Show("安装程序出错：" + ex.Message, AppName, MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 2;
            }
        }
    }

    internal sealed class Installer
    {
        internal sealed class Result
        {
            public bool Ok;
            public string Error = "";
            public bool Cancelled;
            public string Dir = "";
            public int Files;
        }

        // 安装：解压 payload → 写快捷方式 → 写卸载项
        internal static Result Run(Options opts, PayloadInfo info, Action<int, string> report, Func<bool> cancelled)
        {
            Result res = new Result();
            res.Dir = Path.GetFullPath(opts.Dir);
            bool createdRoot = false;
            try
            {
                if (res.Dir.TrimEnd('\\').Length <= 2) throw new InvalidOperationException("不能安装到磁盘根目录");
                if (!Directory.Exists(res.Dir))
                {
                    Directory.CreateDirectory(res.Dir);
                    createdRoot = true;
                }

                // 覆盖安装：先把还开着的旧实例关掉 —— 否则文件虽然能换掉，用户眼前还是旧进程在跑
                // （内存里是旧代码），看起来像「更新没生效」。关不掉也不会卡住安装：
                // 下面释放文件时，遇到占用会「挪开旧的再写新的」（Windows 允许重命名正在使用的文件）。
                bool upgrading = File.Exists(Path.Combine(res.Dir, Program.AppName + ".exe"));
                if (upgrading)
                {
                    if (report != null) report(1, "正在关闭正在运行的程序…");
                    CloseRunningApp(res.Dir, opts.Silent);
                    // 进程被杀之后，它加载的 dll 句柄还会残留一小会儿，等它们真的可写再释放文件
                    WaitForWritable(res.Dir, 12000);
                }

                using (Stream s = Program.OpenPayload())
                using (ZipArchive zip = new ZipArchive(s, ZipArchiveMode.Read))
                {
                    int total = 0;
                    foreach (ZipArchiveEntry e in zip.Entries)
                    {
                        string n = e.FullName.Replace('\\', '/');
                        if (!n.EndsWith("/", StringComparison.Ordinal)) total++;
                    }
                    int done = 0;
                    foreach (ZipArchiveEntry entry in zip.Entries)
                    {
                        if (cancelled != null && cancelled()) { res.Cancelled = true; throw new OperationCanceledException(); }
                        // zip 里的目录项可能用 / 也可能用反斜杠，统一按 / 判断
                        string name = entry.FullName.Replace('\\', '/');
                        if (name.EndsWith("/", StringComparison.Ordinal)) continue;
                        string rel = name.Replace('/', Path.DirectorySeparatorChar);
                        string dest = Path.Combine(res.Dir, rel);
                        string dir = Path.GetDirectoryName(dest);
                        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
                        using (Stream src = entry.Open())
                        {
                            WriteFileReplacing(dest, src);
                        }
                        done++;
                        if (report != null) report((int)(90.0 * done / Math.Max(1, total)), "正在释放文件：" + Path.GetFileName(dest));
                    }
                }

                if (report != null) report(92, "正在准备卸载程序…");
                string self = Application.ExecutablePath;
                string uninstaller = Path.Combine(res.Dir, "uninstall.exe");
                File.Copy(self, uninstaller, true);

                Directory.CreateDirectory(Path.Combine(res.Dir, "reports"));

                string exe = Path.Combine(res.Dir, Program.AppName + ".exe");
                if (!opts.NoDesktop)
                {
                    if (report != null) report(95, "正在创建桌面快捷方式…");
                    Shortcuts.Create(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), Program.AppName + ".lnk"), exe, res.Dir);
                }
                if (!opts.NoMenu)
                {
                    if (report != null) report(97, "正在创建开始菜单快捷方式…");
                    string programs = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
                    Shortcuts.Create(Path.Combine(programs, Program.AppName + ".lnk"), exe, res.Dir);
                }

                if (report != null) report(99, "正在写入卸载信息…");
                Registry.Write(res.Dir, info.Version);

                res.Files = info.Files;
                res.Ok = true;
                if (report != null) report(100, "完成");
            }
            catch (OperationCanceledException)
            {
                res.Ok = false;
                res.Cancelled = true;
                Rollback(res.Dir, createdRoot);
            }
            catch (Exception ex)
            {
                res.Ok = false;
                res.Error = ex.Message;
                Program.Log("安装出错（" + res.Dir + "）：" + ex.ToString());
                Rollback(res.Dir, createdRoot);
            }
            return res;
        }

        private static void Rollback(string dir, bool createdRoot)
        {
            try
            {
                if (createdRoot && Directory.Exists(dir)) Directory.Delete(dir, true);
            }
            catch { }
        }

        // 覆盖安装前：把还开着的旧实例关掉。
        //   ① 主窗口（宿主 powershell，标题就是程序名）→ 先礼貌关窗口
        //   ② 关不掉再问用户（图形界面）或直接结束（静默安装）
        //   ③ 兜底按「映像路径在安装目录下」结束（启动器无窗口，名字也叫 PerfCapture）
        private static void CloseRunningApp(string dir, bool silent)
        {
            string target = "";
            try { target = Path.GetFullPath(dir).TrimEnd('\\'); } catch { }

            var hosts = new System.Collections.Generic.List<Process>();
            foreach (Process p in Process.GetProcesses())
            {
                try
                {
                    if (p.Id == Process.GetCurrentProcess().Id) continue;
                    string title = p.MainWindowTitle;
                    if (!string.IsNullOrEmpty(title) && title.IndexOf(Program.AppName, StringComparison.OrdinalIgnoreCase) >= 0)
                        hosts.Add(p);
                }
                catch { }
            }

            foreach (Process p in hosts)
            {
                try
                {
                    Program.Log("安装：请求关闭窗口「" + p.MainWindowTitle + "」(pid " + p.Id + ")");
                    p.CloseMainWindow();
                }
                catch { }
            }

            // 等活动窗口收尾（WebView2 拆除要几秒）。
            // 注意：跨提权读 HasExited 可能抛异常，读不到时必须当作「还活着」，否则会误判成已退出。
            for (int i = 0; i < 40; i++)
            {
                bool anyAlive = false;
                foreach (Process p in hosts)
                {
                    bool alive = true;
                    try { p.Refresh(); alive = !p.HasExited; } catch { alive = true; }
                    if (alive) { anyAlive = true; }
                }
                if (!anyAlive) break;
                System.Threading.Thread.Sleep(250);
            }

            bool kill = silent;
            if (!silent)
            {
                bool stillAlive = false;
                foreach (Process p in hosts)
                {
                    bool alive = true;
                    try { p.Refresh(); alive = !p.HasExited; } catch { alive = true; }
                    if (alive) { stillAlive = true; }
                }
                if (stillAlive)
                {
                    DialogResult r = MessageBox.Show(
                        Program.AppName + " 还在运行，安装需要先关闭它。\r\n\r\n是否结束这些进程并继续安装？",
                        Program.AppName + " 安装程序", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                    kill = (r == DialogResult.Yes);
                }
                else { kill = true; }
            }

            if (kill)
            {
                foreach (Process p in hosts)
                {
                    try
                    {
                        Program.Log("安装：结束进程 pid " + p.Id);
                        p.Kill();
                    }
                    catch { }
                }
            }

            if (kill || silent) KillProcessesFromDir(target);
            System.Threading.Thread.Sleep(400);
        }

        // 结束所有「映像文件位于 dir 下」的进程（安装程序自己是例外）。
        private static void KillProcessesFromDir(string dir)
        {
            if (string.IsNullOrEmpty(dir)) return;
            string target = dir.TrimEnd('\\');
            foreach (Process p in Process.GetProcesses())
            {
                try
                {
                    if (p.Id == Process.GetCurrentProcess().Id) continue;
                    string path = "";
                    try { path = p.MainModule.FileName; } catch { continue; }
                    if (string.IsNullOrEmpty(path)) continue;
                    string pdir = Path.GetDirectoryName(Path.GetFullPath(path));
                    if (pdir == null) continue;
                    if (!string.Equals(pdir.TrimEnd('\\'), target, StringComparison.OrdinalIgnoreCase)) continue;
                    Program.Log("安装：结束该目录下的进程 " + p.ProcessName + " (pid " + p.Id + ")");
                    p.Kill();
                }
                catch { }
            }
        }

        // 写文件；目标被占用时先把它挪开（Windows 允许重命名正在使用的文件），再写新的。
        // 旧文件留成 <name>.old，下次安装会覆盖或清掉。
        private static void WriteFileReplacing(string dest, Stream src)
        {
            try
            {
                using (FileStream dst = File.Create(dest)) { src.CopyTo(dst); }
                return;
            }
            catch (IOException)
            {
                string aside = dest + ".old";
                Exception last = null;
                for (int attempt = 0; attempt < 3; attempt++)
                {
                    try
                    {
                        if (File.Exists(aside)) { try { File.Delete(aside); } catch { } }
                        File.Move(dest, aside);
                        Program.Log("安装：文件被占用，已挪开旧的再写新的：" + dest);
                        src.Position = 0;
                        using (FileStream dst2 = File.Create(dest)) { src.CopyTo(dst2); }
                        return;
                    }
                    catch (Exception ex)
                    {
                        last = ex;
                        System.Threading.Thread.Sleep(800);
                    }
                }
                throw new IOException("安装文件被占用且无法替换：" + dest, last);
            }
        }

        // 等目录里的文件变成「可独占写入」（进程刚被杀时句柄释放有延迟）
        private static void WaitForWritable(string dir, int timeoutMs)
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < timeoutMs)
            {
                string first = "";
                try
                {
                    foreach (string f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories))
                    {
                        try { using (FileStream fs = new FileStream(f, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { } }
                        catch { first = f; break; }
                    }
                }
                catch { return; }
                if (first.Length == 0) return;
                System.Threading.Thread.Sleep(400);
            }
        }
    }

    internal static class Shortcuts
    {
        internal static void Create(string linkPath, string target, string workDir)
        {
            Type shellType = Type.GetTypeFromProgID("WScript.Shell");
            if (shellType == null) throw new InvalidOperationException("系统缺少 WScript.Shell，无法创建快捷方式");
            object shell = Activator.CreateInstance(shellType);
            object link = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { linkPath });
            Type lt = link.GetType();
            lt.InvokeMember("TargetPath", BindingFlags.SetProperty, null, link, new object[] { target });
            lt.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, link, new object[] { workDir });
            lt.InvokeMember("IconLocation", BindingFlags.SetProperty, null, link, new object[] { target + ",0" });
            lt.InvokeMember("Description", BindingFlags.SetProperty, null, link, new object[] { Program.AppName });
            lt.InvokeMember("Save", BindingFlags.InvokeMethod, null, link, null);
        }

        internal static void Delete(params string[] paths)
        {
            foreach (string p in paths)
            {
                try { if (File.Exists(p)) File.Delete(p); }
                catch { }
            }
        }
    }

    internal static class Registry
    {
        internal static void Write(string installDir, string version)
        {
            using (RegistryKey k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(Program.UninstallKey))
            {
                string exe = Path.Combine(installDir, Program.AppName + ".exe");
                k.SetValue("DisplayName", Program.AppName);
                k.SetValue("DisplayVersion", version);
                k.SetValue("Publisher", Program.Publisher);
                k.SetValue("InstallLocation", installDir);
                k.SetValue("DisplayIcon", exe + ",0");
                k.SetValue("UninstallString", "\"" + Path.Combine(installDir, "uninstall.exe") + "\" /U");
                k.SetValue("QuietUninstallString", "\"" + Path.Combine(installDir, "uninstall.exe") + "\" /U /S");
                k.SetValue("NoModify", 1, RegistryValueKind.DWord);
                k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                try
                {
                    long kb = 0;
                    foreach (string f in Directory.GetFiles(installDir, "*", SearchOption.AllDirectories))
                        kb += new FileInfo(f).Length;
                    k.SetValue("EstimatedSize", (int)(kb / 1024), RegistryValueKind.DWord);
                }
                catch { }
            }
        }

        internal static string ReadInstallLocation()
        {
            try
            {
                using (RegistryKey k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(Program.UninstallKey))
                {
                    if (k == null) return "";
                    object v = k.GetValue("InstallLocation");
                    return v == null ? "" : v.ToString();
                }
            }
            catch { return ""; }
        }

        internal static void DeleteKey()
        {
            try { Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(Program.UninstallKey, false); }
            catch { }
        }
    }

    internal static class Uninstaller
    {
        internal static int Run(Options opts)
        {
            string dir = Registry.ReadInstallLocation();
            if (dir.Length == 0) dir = Path.GetDirectoryName(Application.ExecutablePath);
            // 只有目录可信才删：注册表被改坏时，「删整个目录」这个动作可能指向盘根或 Windows。
            string full = SafeInstallDir(dir);
            if (!opts.Silent)
            {
                string shown = full.Length > 0 ? full : dir;
                DialogResult r = MessageBox.Show(
                    "确定要卸载 " + Program.AppName + " 吗？\r\n\r\n安装目录：" + shown + "\r\n（配置与历史报告会保留在 " + Program.DataDir() + "）",
                    Program.AppName + " 卸载", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (r != DialogResult.Yes) return 3;
            }

            Shortcuts.Delete(
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), Program.AppName + ".lnk"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), Program.AppName + ".lnk"));
            Registry.DeleteKey();

            if (full.Length > 0)
            {
                // 自己删自己：当前 exe 锁着自己的目录，所以交给 cmd 等几秒再删。
                // 注意两件事：① cmd 的工作目录不能是安装目录（CWD 被占用时 rmdir 会失败）；
                //           ② 删一次不够稳（杀软/索引器可能还短暂占着文件），隔 2 秒再补一次。
                try
                {
                    string cmd = "/c cd /d \"" + Path.GetTempPath() + "\" & ping -n 3 127.0.0.1 > nul & rmdir /s /q \"" + full + "\" & ping -n 2 127.0.0.1 > nul & if exist \"" + full + "\" rmdir /s /q \"" + full + "\"";
                    ProcessStartInfo psi = new ProcessStartInfo("cmd.exe", cmd);
                    psi.WorkingDirectory = Path.GetTempPath();
                    psi.WindowStyle = ProcessWindowStyle.Hidden;
                    psi.CreateNoWindow = true;
                    Process.Start(psi);
                }
                catch { }
            }
            else
            {
                Program.Log("卸载：安装目录不可信，已跳过删除目录：" + (dir == null ? "(null)" : dir));
            }
            return 0;
        }

        // 判定安装目录是否可信：绝对路径、已存在、不是盘根、不在 Windows 目录下，
        // 并且目录里确实有本程序的 exe（或是卸载程序自己所在的目录）。
        private static string SafeInstallDir(string dir)
        {
            try
            {
                if (string.IsNullOrEmpty(dir)) return "";
                string full = Path.GetFullPath(dir).TrimEnd('\\');
                if (full.Length <= 3) return "";
                if (!Directory.Exists(full)) return "";
                string rootPath = Path.GetPathRoot(full);
                if (rootPath != null && string.Equals(full, rootPath.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) return "";
                string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
                win = win == null ? "" : win.TrimEnd('\\');
                if (win.Length > 0 && full.StartsWith(win + "\\", StringComparison.OrdinalIgnoreCase)) return "";
                bool hasApp = File.Exists(Path.Combine(full, Program.AppName + ".exe"));
                string self = Path.GetDirectoryName(Application.ExecutablePath) ?? "";
                bool isSelf = self.Length > 0 &&
                    string.Equals(full, Path.GetFullPath(self).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
                if (!hasApp && !isSelf) return "";
                return full;
            }
            catch { return ""; }
        }
    }
}
