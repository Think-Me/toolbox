using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;

namespace Toolbox.Elevated;

/// <summary>
/// 提权 helper：**只做** hosts 写入/备份/恢复 + DNS 刷新。
/// 安全边界：只接受「一个文件路径」（--apply）或 --restore，不接受任意命令拼接。
/// 运行在管理员权限下，任何多余能力都是攻击面。
/// 结果写进 &lt;临时文件&gt;.result（JSON），因为 runas 启动没法重定向 stdout。
/// </summary>
internal static class Program
{
    private const string HostsPath = @"C:\Windows\System32\drivers\etc\hosts";
    private const int MaxBackups = 50;

    private static string BackupDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "Toolbox", "hosts");

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 2 && args[0] == "--apply") return Apply(args[1]);
            if (args.Length == 1 && args[0] == "--restore") return Restore();
            return 1;   // 参数不对：没有可靠的结果文件可写，只能用退出码
        }
        catch (Exception error)
        {
            TryLog("helper 未处理异常：" + error.Message);
            return 1;
        }
    }

    private static int Apply(string tempFile)
    {
        var resultFile = tempFile + ".result";
        try
        {
            if (!File.Exists(tempFile)) return Fail(resultFile, "临时文件不存在");
            var content = File.ReadAllText(tempFile);

            Directory.CreateDirectory(BackupDirectory);

            // 首次写入前把原始 hosts 存下来，--restore 恢复的就是它
            var original = Path.Combine(BackupDirectory, "original.hosts");
            if (!File.Exists(original)) File.Copy(HostsPath, original);

            var backup = Path.Combine(BackupDirectory, $"backup-{DateTime.Now:yyyyMMdd-HHmmss}.hosts");
            File.Copy(HostsPath, backup);
            PruneBackups();

            File.WriteAllText(HostsPath, content, new UTF8Encoding(false));

            var dns = FlushDns();
            return Ok(resultFile, $"hosts 已更新（DNS {dns}）");
        }
        catch (Exception error)
        {
            return Fail(resultFile, error.Message);
        }
    }

    private static int Restore()
    {
        // App 侧只传 --restore（没有临时文件），结果写在固定位置
        var resultFile = Path.Combine(Path.GetTempPath(), "toolbox-hosts-restore.result");
        try
        {
            var original = Path.Combine(BackupDirectory, "original.hosts");
            if (!File.Exists(original)) return Fail(resultFile, "没有原始 hosts 备份，无法恢复");

            File.Copy(original, HostsPath, overwrite: true);
            var dns = FlushDns();
            return Ok(resultFile, $"hosts 已恢复原始备份（DNS {dns}）");
        }
        catch (Exception error)
        {
            return Fail(resultFile, error.Message);
        }
    }

    private static string FlushDns()
    {
        using var process = Process.Start(new ProcessStartInfo("ipconfig", "/flushdns")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
        });
        if (process is null) return "刷新失败";
        process.WaitForExit(15_000);
        return process.ExitCode == 0 ? "已刷新" : $"刷新失败（{process.ExitCode}）";
    }

    private static void PruneBackups()
    {
        var stale = Directory.GetFiles(BackupDirectory, "backup-*.hosts")
            .Select(path => new FileInfo(path))
            .OrderByDescending(f => f.LastWriteTimeUtc)
            .Skip(MaxBackups);
        foreach (var file in stale)
        {
            try { file.Delete(); } catch { }
        }
    }

    private static int Ok(string resultFile, string message) => WriteResult(resultFile, true, message);

    private static int Fail(string resultFile, string message)
    {
        TryLog(message);
        return WriteResult(resultFile, false, message);
    }

    private static int WriteResult(string resultFile, bool ok, string message)
    {
        try
        {
            var json = JsonSerializer.Serialize(new { ok, message });
            File.WriteAllText(resultFile, json, new UTF8Encoding(false));
        }
        catch
        {
            // 结果写不回去就只能靠退出码了
        }
        return ok ? 0 : 1;
    }

    private static void TryLog(string message)
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Toolbox", "logs");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "elevated.log"),
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {message}{Environment.NewLine}");
        }
        catch
        {
            // 连日志都写不进就只能放弃
        }
    }
}
