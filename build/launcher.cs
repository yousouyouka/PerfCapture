// PerfCapture launcher
// 作用：吞掉控制台黑窗，转调 src\PerfCapture.ps1，并把失败原因用对话框告诉用户。
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        string exeDir = AppDomain.CurrentDomain.BaseDirectory;
        string ps1 = Path.Combine(exeDir, @"src\PerfCapture.ps1");

        if (!File.Exists(ps1))
        {
            MessageBox.Show(
                "找不到程序主体：\n" + ps1 +
                "\n\n请确认压缩包已完整解压（不要直接在压缩包里双击运行）。",
                "PerfCapture", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\"",
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = exeDir
        };

        try
        {
            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "启动失败：" + ex.Message +
                "\n\n可能原因：Windows PowerShell 被策略禁用，或杀毒软件拦截。",
                "PerfCapture", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
