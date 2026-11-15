// PerfCapture 安装向导（Inno Setup 风格五页向导：欢迎 / 目标位置 / 附加任务 / 安装进度 / 完成）
// 与 setup-core.cs 一起用 csc 编译成单个 exe。
//
// 排版规则（照 Inno Setup 的传统向导，不自定义花活）：
//   顶部：页标题（粗体 12pt）+ 副标题（9pt 灰）+ 细横线
//   中部：内容区（页面面板，左对齐，22px 边距）
//   底部：浅灰条 + 上边线，按钮右对齐「上一步 / 下一步 / 取消」，完成页「完成」
//
// DPI：exe 由 build\setup-dpi.manifest 声明 PerMonitorV2（否则整窗被位图拉伸 = 糊），
//      本文件因此 **AutoScaleMode = None**、只把逻辑像素乘一次 scale，字号一律用 pt
//      （GDI 自己按窗口 DPI 换算，再乘一次就会二次放大）。同 60-Capture.ps1 的导出提示窗。
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

namespace PerfCaptureSetup
{
    internal sealed class SetupForm : Form
    {
        // 逻辑尺寸（96 DPI 下的像素），实际大小 = 逻辑值 * scale
        private const int BaseW = 520;
        private const int BaseH = 386;
        private const int ContentX = 22;
        private const int ContentY = 88;
        private const int ContentW = 476;
        private const int BandY = 312;

        private static readonly Color C_Text = Color.FromArgb(30, 30, 30);
        private static readonly Color C_Muted = Color.FromArgb(94, 94, 94);
        private static readonly Color C_Hint = Color.FromArgb(120, 116, 132);
        private static readonly Color C_Line = Color.FromArgb(214, 210, 206);
        private static readonly Color C_Band = Color.FromArgb(243, 243, 243);

        private readonly float scale = 1f;
        private readonly Options opts;
        private readonly PayloadInfo info;

        private int page;
        private Panel[] panels;
        private Label titleLabel;
        private Label subLabel;
        private Button backButton;
        private Button nextButton;
        private Button cancelButton;

        private TextBox pathBox;
        private CheckBox desktopBox;
        private CheckBox menuBox;
        private CheckBox runBox;
        private Label progressLabel;
        private ProgressBar progressBar;
        private Label finishLabel;
        private LinkLabel openLink;

        private volatile bool cancelRequested;
        private bool installed;
        private string installDir = "";

        internal int ExitCode = 0;

        // ---------- 逻辑坐标 → 物理像素 ----------
        private int S(int v) { return (int)Math.Round(v * scale); }

        private static Font Reg(float pt) { return new Font("Microsoft YaHei UI", pt, FontStyle.Regular); }
        private static Font Bold(float pt) { return new Font("Microsoft YaHei UI", pt, FontStyle.Bold); }

        internal SetupForm(Options o, PayloadInfo pi)
        {
            opts = o;
            info = pi;

            // DPI 只按一次算：进程已 PerMonitorV2 感知，控件自动缩放必须关掉
            AutoScaleMode = AutoScaleMode.None;
            try
            {
                using (Graphics g = CreateGraphics()) { scale = g.DpiX / 96f; }
            }
            catch { }
            if (scale < 1f) scale = 1f;

            Text = Program.AppName + " " + pi.Version + " 安装程序";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = true;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(251, 251, 251);
            Font = Reg(9F);
            ClientSize = new Size(S(BaseW), S(BaseH));
            DoubleBuffered = true;

            BuildHeader();
            BuildBody();
            BuildBottom();
            ShowPage(0);
        }

        // ---------- 顶部标题区 ----------
        private void BuildHeader()
        {
            titleLabel = new Label();
            titleLabel.AutoSize = false;
            titleLabel.UseCompatibleTextRendering = false;
            titleLabel.TextAlign = ContentAlignment.MiddleLeft;
            titleLabel.Font = Bold(12F);
            titleLabel.ForeColor = C_Text;
            titleLabel.SetBounds(S(ContentX), S(18), S(ContentW), S(26));
            Controls.Add(titleLabel);

            subLabel = new Label();
            subLabel.AutoSize = false;
            subLabel.UseCompatibleTextRendering = false;
            subLabel.TextAlign = ContentAlignment.MiddleLeft;
            subLabel.Font = Reg(9F);
            subLabel.ForeColor = C_Muted;
            subLabel.SetBounds(S(ContentX), S(48), S(ContentW), S(20));
            Controls.Add(subLabel);

            Panel line = new Panel();
            line.BackColor = C_Line;
            line.SetBounds(S(ContentX), S(76), S(ContentW), 1);
            Controls.Add(line);
        }

        // ---------- 内容区（5 个页面面板） ----------
        private void BuildBody()
        {
            panels = new Panel[5];
            for (int i = 0; i < panels.Length; i++)
            {
                panels[i] = new Panel();
                panels[i].SetBounds(S(ContentX), S(ContentY), S(ContentW), S(BandY - ContentY - 6));
                panels[i].Visible = false;
                panels[i].AutoScroll = false;
                Controls.Add(panels[i]);
            }
            BuildWelcome();
            BuildPath();
            BuildOptions();
            BuildProgress();
            BuildFinish();
        }

        // 一段会自动折行的文字，返回下一行的逻辑 y
        private int AddPara(Panel p, int x, int y, int w, string s, float pt, Color color, int gap)
        {
            Label l = new Label();
            l.AutoSize = false;
            l.UseCompatibleTextRendering = false;
            l.TextAlign = ContentAlignment.TopLeft;
            l.Font = Reg(pt);
            l.ForeColor = color;
            l.Text = s;
            int h = TextRenderer.MeasureText(s, l.Font, new Size(S(w), 10000),
                TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl).Height;
            l.SetBounds(S(x), S(y), S(w), Math.Max(h, 1));
            p.Controls.Add(l);
            return y + (int)Math.Ceiling(l.Height / scale) + gap;
        }

        private void BuildWelcome()
        {
            Panel p = panels[0];
            string gb = (info.Bytes / 1024.0 / 1024.0).ToString("0.0");
            int y = 0;
            y = AddPara(p, 0, y, ContentW,
                Program.AppName + " " + info.Version + " 是零注入的游戏性能采集工具。建议在继续之前关闭其他应用程序。",
                9F, C_Text, 14);
            y = AddPara(p, 0, y, ContentW,
                "· 用 PresentMon 的 ETW 事件读取帧时间，不向游戏注入任何 DLL，不挂任何覆盖层\r\n"
                + "· 因此不会触发反作弊检查与 DLSS 的驱动门禁，也不影响游戏本身\r\n"
                + "· 采集平均帧率、1% Low、帧时间、上屏延迟与 GPU 状态，并生成报告与长图",
                9F, C_Text, 16);
            y = AddPara(p, 0, y, ContentW,
                "安装体积约 " + gb + " MB（" + info.Files + " 个文件）。按当前用户安装，安装过程不需要管理员权限；"
                + "运行采集时需要管理员权限（读取 ETW），程序启动时会自行请求提升。",
                8.5F, C_Muted, 8);
            AddPara(p, 0, y, ContentW, "默认安装位置：" + Program.DefaultDir(), 8.5F, C_Hint, 0);
        }

        private void BuildPath()
        {
            Panel p = panels[1];
            int y = 0;
            y = AddPara(p, 0, y, ContentW,
                "安装程序将把 " + Program.AppName + " 安装到下面的文件夹中。要安装到其他文件夹，点「浏览…」或直接输入路径。",
                9F, C_Text, 12);

            Label cap = new Label();
            cap.AutoSize = false;
            cap.UseCompatibleTextRendering = false;
            cap.TextAlign = ContentAlignment.MiddleLeft;
            cap.Font = Reg(9F);
            cap.ForeColor = C_Text;
            cap.Text = "目标文件夹：";
            cap.SetBounds(S(0), S(y), S(ContentW), S(18));
            p.Controls.Add(cap);
            y += 24;

            pathBox = new TextBox();
            pathBox.SetBounds(S(0), S(y), S(380), S(24));
            pathBox.Text = opts.Dir.Length > 0 ? opts.Dir : Program.DefaultDir();
            p.Controls.Add(pathBox);

            Button browse = new Button();
            browse.Text = "浏览…";
            browse.Font = Reg(9F);
            browse.UseVisualStyleBackColor = true;
            browse.SetBounds(S(388), pathBox.Top, S(88), pathBox.Height);
            browse.Click += delegate
            {
                using (FolderBrowserDialog d = new FolderBrowserDialog())
                {
                    d.Description = "选择 " + Program.AppName + " 的安装目录";
                    d.SelectedPath = pathBox.Text;
                    if (d.ShowDialog(this) == DialogResult.OK) pathBox.Text = d.SelectedPath;
                }
            };
            p.Controls.Add(browse);
            y += 40;

            AddPara(p, 0, y, ContentW,
                "提示：安装到 C:\\Program Files 需要以管理员身份运行安装程序。无论装到哪里，"
                + "配置与历史报告都写在 " + Program.DataDir() + "，与安装位置无关。",
                8.5F, C_Hint, 0);
        }

        private void BuildOptions()
        {
            Panel p = panels[2];
            int y = 4;

            Label cap = new Label();
            cap.AutoSize = false;
            cap.UseCompatibleTextRendering = false;
            cap.TextAlign = ContentAlignment.MiddleLeft;
            cap.Font = Reg(9F);
            cap.ForeColor = C_Text;
            cap.Text = "选择安装程序要执行的附加任务：";
            cap.SetBounds(S(0), S(y), S(ContentW), S(18));
            p.Controls.Add(cap);
            y += 26;

            desktopBox = new CheckBox();
            desktopBox.Text = "创建桌面快捷方式";
            desktopBox.Font = Reg(9F);
            desktopBox.ForeColor = C_Text;
            desktopBox.UseVisualStyleBackColor = true;
            desktopBox.Checked = !opts.NoDesktop;
            desktopBox.SetBounds(S(0), S(y), S(ContentW), S(22));
            p.Controls.Add(desktopBox);
            y += 26;

            menuBox = new CheckBox();
            menuBox.Text = "创建开始菜单快捷方式";
            menuBox.Font = Reg(9F);
            menuBox.ForeColor = C_Text;
            menuBox.UseVisualStyleBackColor = true;
            menuBox.Checked = !opts.NoMenu;
            menuBox.SetBounds(S(0), S(y), S(ContentW), S(22));
            p.Controls.Add(menuBox);
            y += 34;

            AddPara(p, 0, y, ContentW,
                "安装程序会：① 把程序文件释放到安装目录；② 创建上面勾选的快捷方式；"
                + "③ 在「设置 → 应用」里登记卸载项（卸载不会删除配置与历史报告）。",
                8.5F, C_Muted, 0);
        }

        private void BuildProgress()
        {
            Panel p = panels[3];
            progressLabel = new Label();
            progressLabel.AutoSize = false;
            progressLabel.UseCompatibleTextRendering = false;
            progressLabel.TextAlign = ContentAlignment.MiddleLeft;
            progressLabel.Font = Reg(9F);
            progressLabel.ForeColor = C_Text;
            progressLabel.Text = "准备安装…";
            progressLabel.SetBounds(S(0), S(40), S(ContentW), S(22));
            p.Controls.Add(progressLabel);

            progressBar = new ProgressBar();
            progressBar.Minimum = 0;
            progressBar.Maximum = 100;
            progressBar.SetBounds(S(0), S(74), S(ContentW), S(16));
            p.Controls.Add(progressBar);

            AddPara(p, 0, 110, ContentW,
                "安装过程中可以点「取消」，已经释放的文件会被回滚删除。",
                8.5F, C_Hint, 0);
        }

        private void BuildFinish()
        {
            Panel p = panels[4];

            finishLabel = new Label();
            finishLabel.AutoSize = false;
            finishLabel.UseCompatibleTextRendering = false;
            finishLabel.TextAlign = ContentAlignment.TopLeft;
            finishLabel.Font = Reg(9F);
            finishLabel.ForeColor = C_Text;
            finishLabel.Text = "";
            finishLabel.SetBounds(S(0), 0, S(ContentW), S(100));
            p.Controls.Add(finishLabel);

            runBox = new CheckBox();
            runBox.Text = "运行 " + Program.AppName;
            runBox.Font = Reg(9F);
            runBox.ForeColor = C_Text;
            runBox.UseVisualStyleBackColor = true;
            runBox.Checked = !opts.NoRun;
            runBox.SetBounds(S(0), S(110), S(ContentW), S(22));
            p.Controls.Add(runBox);

            openLink = new LinkLabel();
            openLink.AutoSize = false;
            openLink.UseCompatibleTextRendering = false;
            openLink.TextAlign = ContentAlignment.MiddleLeft;
            openLink.Font = Reg(9F);
            openLink.Text = "打开安装目录";
            openLink.LinkBehavior = LinkBehavior.SystemDefault;
            openLink.SetBounds(S(0), S(140), S(ContentW), S(20));
            openLink.Visible = false;
            openLink.LinkClicked += delegate
            {
                try { Process.Start("explorer.exe", "\"" + installDir + "\""); }
                catch { }
            };
            p.Controls.Add(openLink);
        }

        // ---------- 底部按钮条 ----------
        private void BuildBottom()
        {
            Panel band = new Panel();
            band.BackColor = C_Band;
            band.SetBounds(0, S(BandY), S(BaseW), S(BaseH) - S(BandY));
            Controls.Add(band);

            Panel topLine = new Panel();
            topLine.BackColor = C_Line;
            topLine.SetBounds(0, 0, band.Width, 1);
            band.Controls.Add(topLine);

            // 按钮作为底条的兄弟控件、坐标相对底条（band.Controls 里 z 序天然正确）
            int by = 24;
            backButton = new Button();
            backButton.Text = "上一步";
            backButton.Font = Reg(9F);
            backButton.UseVisualStyleBackColor = true;
            backButton.SetBounds(S(218), S(by), S(84), S(26));
            backButton.Click += delegate { if (page > 0) ShowPage(page - 1); };
            band.Controls.Add(backButton);

            nextButton = new Button();
            nextButton.Text = "下一步";
            nextButton.Font = Reg(9F);
            nextButton.UseVisualStyleBackColor = true;
            nextButton.SetBounds(S(310), S(by), S(96), S(26));
            nextButton.Click += delegate { OnNext(); };
            band.Controls.Add(nextButton);

            cancelButton = new Button();
            cancelButton.Text = "取消";
            cancelButton.Font = Reg(9F);
            cancelButton.UseVisualStyleBackColor = true;
            cancelButton.SetBounds(S(414), S(by), S(84), S(26));
            cancelButton.Click += delegate { OnCancel(); };
            band.Controls.Add(cancelButton);

            AcceptButton = nextButton;
            CancelButton = cancelButton;
        }

        // ---------- 页面切换 ----------
        private void ShowPage(int i)
        {
            page = i;
            for (int k = 0; k < panels.Length; k++) panels[k].Visible = (k == i);
            switch (i)
            {
                case 0:
                    titleLabel.Text = "欢迎使用 " + Program.AppName + " " + info.Version + " 安装向导";
                    subLabel.Text = "此向导将引导你完成 " + Program.AppName + " 的安装。";
                    break;
                case 1:
                    titleLabel.Text = "选择目标位置";
                    subLabel.Text = "安装程序将把 " + Program.AppName + " 安装到下面的文件夹中。";
                    break;
                case 2:
                    titleLabel.Text = "选择附加任务";
                    subLabel.Text = "选择安装程序要执行的附加任务。";
                    break;
                case 3:
                    titleLabel.Text = "正在安装";
                    subLabel.Text = "安装程序正在安装 " + Program.AppName + "，请稍候。";
                    break;
                default:
                    titleLabel.Text = "正在完成 " + Program.AppName + " 安装向导";
                    subLabel.Text = Program.AppName + " 已安装完成。";
                    break;
            }

            backButton.Visible = (i == 1 || i == 2);
            nextButton.Visible = (i != 3);
            nextButton.Text = (i == 4) ? "完成" : "下一步";
            cancelButton.Visible = true;
            cancelButton.Text = "取消";
            cancelButton.Enabled = true;

            if (i != 3) { try { ActiveControl = nextButton; } catch { } }
        }

        private void OnNext()
        {
            switch (page)
            {
                case 0:
                    ShowPage(1);
                    break;
                case 1:
                    {
                        string dir = pathBox.Text.Trim().Trim('"');
                        if (dir.Length == 0)
                        {
                            MessageBox.Show(this, "请填写安装目录。", Program.AppName, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                            pathBox.Focus();
                            return;
                        }
                        try { dir = Path.GetFullPath(dir); }
                        catch (Exception ex)
                        {
                            MessageBox.Show(this, "安装目录不合法：" + ex.Message, Program.AppName, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                            return;
                        }
                        pathBox.Text = dir;
                        opts.Dir = dir;
                        ShowPage(2);
                        break;
                    }
                case 2:
                    DoInstall();
                    break;
                case 4:
                    opts.NoRun = !runBox.Checked;
                    if (installed && runBox.Checked) TryRun();
                    Close();
                    break;
            }
        }

        private void DoInstall()
        {
            // 注意：/NORUN 由完成页的「运行」勾选决定（传统 Inno 行为），这里不动 opts.NoRun
            opts.NoDesktop = !desktopBox.Checked;
            opts.NoMenu = !menuBox.Checked;

            ShowPage(3);
            progressBar.Value = 0;
            progressLabel.Text = "准备安装…";
            cancelRequested = false;
            Application.DoEvents();

            Installer.Result r = Installer.Run(
                opts,
                info,
                delegate(int pct, string text)
                {
                    if (pct >= 0) progressBar.Value = Math.Min(100, Math.Max(progressBar.Value, pct));
                    if (text != null) progressLabel.Text = text;
                    Application.DoEvents();
                },
                delegate { return cancelRequested; });

            if (r.Ok)
            {
                installed = true;
                installDir = r.Dir;
                progressBar.Value = 100;
                SetFinishText(
                    Program.AppName + " " + info.Version + " 已安装到你的电脑上。\r\n\r\n"
                    + "安装目录：" + r.Dir + "\r\n"
                    + "配置与报告：" + Program.DataDir() + "\r\n"
                    + "卸载：在「设置 → 应用」中找到 " + Program.AppName + "，或运行安装目录里的 uninstall.exe。");
                ShowPage(4);
                return;
            }

            if (r.Cancelled)
            {
                MessageBox.Show(this, "已取消安装，已释放的文件已回滚。", Program.AppName,
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                ShowPage(1);
                return;
            }

            MessageBox.Show(this,
                "安装失败：" + r.Error + "\r\n\r\n常见原因：① PerfCapture 还在运行（先退出程序再装）；② 安装到 C:\\Program Files 需要以管理员身份运行安装程序。",
                Program.AppName, MessageBoxButtons.OK, MessageBoxIcon.Error);
            ShowPage(1);
        }

        // 完成页文字高度随内容变化，勾选框与链接跟着往下排
        private void SetFinishText(string s)
        {
            finishLabel.Text = s;
            int h = TextRenderer.MeasureText(s, finishLabel.Font, new Size(finishLabel.Width, 10000),
                TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl).Height;
            finishLabel.Height = Math.Max(h, 1);
            runBox.Top = finishLabel.Bottom + S(10);
            openLink.Top = runBox.Bottom + S(8);
            openLink.Visible = installed;
        }

        private void TryRun()
        {
            try
            {
                string exe = Path.Combine(installDir, Program.AppName + ".exe");
                if (File.Exists(exe))
                {
                    ProcessStartInfo psi = new ProcessStartInfo(exe);
                    psi.WorkingDirectory = installDir;
                    Process.Start(psi);
                }
            }
            catch { }
        }

        private void OnCancel()
        {
            if (page == 3)
            {
                cancelRequested = true;
                cancelButton.Enabled = false;
                cancelButton.Text = "正在取消…";
                return;
            }
            // 完成页的「取消」等于直接关闭向导（Inno 传统布局里它一直在最右），已经装完了没什么可取消的
            if (page == 4) { Close(); return; }
            if (MessageBox.Show(this, "确定要退出 " + Program.AppName + " 安装向导吗？", Program.AppName,
                MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                Close();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (page == 3 && !installed)
            {
                cancelRequested = true;
                e.Cancel = true;
                return;
            }
            base.OnFormClosing(e);
        }
    }
}
