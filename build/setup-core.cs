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
            try
            {
                if (opts.Uninstall) return Uninstaller.Run(opts);
                PayloadInfo info = ReadPayloadInfo();
                if (opts.Silent)
                {
                    Installer.Result r = Installer.Run(opts, info, null, null);
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
                        using (FileStream dst = File.Create(dest))
                        {
                            src.CopyTo(dst);
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
            if (!opts.Silent)
            {
                DialogResult r = MessageBox.Show(
                    "确定要卸载 " + Program.AppName + " 吗？\r\n\r\n安装目录：" + dir + "\r\n（配置与历史报告会保留在 " + Program.DataDir() + "）",
                    Program.AppName + " 卸载", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (r != DialogResult.Yes) return 3;
            }

            Shortcuts.Delete(
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), Program.AppName + ".lnk"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), Program.AppName + ".lnk"));
            Registry.DeleteKey();

            // 自己删自己：拷到临时目录再让 cmd 删安装目录（当前 exe 锁着目录）
            try
            {
                string cmd = "/c ping -n 3 127.0.0.1 > nul & rmdir /s /q \"" + dir + "\"";
                ProcessStartInfo psi = new ProcessStartInfo("cmd.exe", cmd);
                psi.WindowStyle = ProcessWindowStyle.Hidden;
                psi.CreateNoWindow = true;
                Process.Start(psi);
            }
            catch { }
            return 0;
        }
    }
}
