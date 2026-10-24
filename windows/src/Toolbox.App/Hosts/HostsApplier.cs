using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;

namespace Toolbox.App.Hosts;

internal sealed record HostsApplyOutcome(bool Ok, string Message);

/// <summary>
/// 通过提权 helper 应用 hosts。流程：编译好的内容写临时文件 →
/// runas 启动 Toolbox.Elevated → UAC → helper 备份/写入/flushdns → 结果文件回传。
/// 每次 apply 都会弹一次 UAC（README 已知成本，常驻提权服务留待后续）。
/// </summary>
internal static class HostsApplier
{
    private const string HostsPath = @"C:\Windows\System32\drivers\etc\hosts";

    public static string ReadCurrentHosts() =>
        File.Exists(HostsPath) ? File.ReadAllText(HostsPath) : "";

    /// <summary>content → 临时文件 → --apply。返回临时文件路径，供结果文件名推导。</summary>
    private static string WriteTemp(string content)
    {
        var temp = Path.Combine(Path.GetTempPath(), $"toolbox-hosts-{Guid.NewGuid():N}.txt");
        File.WriteAllText(temp, content);
        return temp;
    }

    public static HostsApplyOutcome Apply(string content)
    {
        var temp = WriteTemp(content);
        return RunElevated($"--apply \"{temp}\"", temp);
    }

    public static HostsApplyOutcome Restore() => RunElevated("--restore", tempFile: null);

    private static HostsApplyOutcome RunElevated(string arguments, string? tempFile)
    {
        var elevated = Path.Combine(AppContext.BaseDirectory, "Toolbox.Elevated.exe");
        if (!File.Exists(elevated)) return new HostsApplyOutcome(false, "找不到 Toolbox.Elevated.exe");

        // 结果文件由 helper 写（runas 启动不能重定向 stdout）
        var resultFile = tempFile is null
            ? Path.Combine(Path.GetTempPath(), "toolbox-hosts-restore.result")
            : tempFile + ".result";

        try
        {
            Process? process;
            try
            {
                process = Process.Start(new ProcessStartInfo(elevated)
                {
                    Arguments = arguments,
                    Verb = "runas",
                    UseShellExecute = true,
                    WindowStyle = ProcessWindowStyle.Hidden,
                });
            }
            catch (Win32Exception error) when (error.NativeErrorCode == 1223)
            {
                // 1223 = ERROR_CANCELLED：用户在 UAC 上点了"否"
                return new HostsApplyOutcome(false, "已取消 UAC 授权，hosts 未修改");
            }

            if (process is null) return new HostsApplyOutcome(false, "提权进程启动失败");
            if (!process.WaitForExit(60_000))
            {
                try { process.Kill(); } catch { /* 已经退了就算了 */ }
                return new HostsApplyOutcome(false, "提权 helper 超时");
            }

            if (!File.Exists(resultFile))
                return new HostsApplyOutcome(process.ExitCode == 0,
                    $"helper 退出码 {process.ExitCode}，无结果回传");

            using var doc = JsonDocument.Parse(File.ReadAllText(resultFile));
            var ok = doc.RootElement.TryGetProperty("ok", out var okElement) &&
                     okElement.ValueKind == JsonValueKind.True;
            var message = doc.RootElement.TryGetProperty("message", out var messageElement)
                ? messageElement.GetString()
                : null;
            return new HostsApplyOutcome(ok, message ?? (ok ? "完成" : "失败"));
        }
        finally
        {
            try { if (tempFile is not null) File.Delete(tempFile); } catch { }
            try { File.Delete(resultFile); } catch { }
        }
    }
}
