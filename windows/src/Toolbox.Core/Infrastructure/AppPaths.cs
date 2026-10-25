namespace Toolbox.Core.Infrastructure;

/// <summary>
/// 设置、数据与日志的落盘位置。集中在一处，免得各模块各拼一遍 %APPDATA% / %LOCALAPPDATA%，
/// 也避免"README 写的是这个路径、代码里是另一个"。
/// 对应 windows/README.md 的「数据与配置」表。
/// </summary>
public sealed class AppPaths
{
    public AppPaths(string roamingRoot, string localRoot)
    {
        RoamingRoot = roamingRoot;
        LocalRoot = localRoot;
    }

    /// <summary>真实运行时的位置。测试用构造函数传临时目录，不要用这个。</summary>
    public static AppPaths Standard() => new(
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Toolbox"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Toolbox"));

    public string RoamingRoot { get; }
    public string LocalRoot { get; }

    public string Settings => Path.Combine(RoamingRoot, "settings.json");

    public string HostsRules => Path.Combine(RoamingRoot, "hosts", "rules.json");

    /// <summary>AI Key 用 DPAPI 加密后单独存，不写进 settings.json。</summary>
    public string AiKeyFile => Path.Combine(RoamingRoot, "ai.key");

    /// <summary>xray 内核 + geo 规则 + config.json 的工作目录（可写，config 要和 geo 同目录）。</summary>
    public string ProxyDirectory => Path.Combine(LocalRoot, "proxy");

    /// <summary>代理节点库。</summary>
    public string ProxyLibrary => Path.Combine(RoamingRoot, "proxy", "nodes.json");

    public string ClipboardDatabase => Path.Combine(LocalRoot, "clipboard.db");

    public string MediaDirectory => Path.Combine(LocalRoot, "media");

    public string LogsDirectory => Path.Combine(LocalRoot, "logs");

    /// <summary>`--probe` 的输出。WinExe 没有控制台，只能落文件。</summary>
    public string ProbeReport => Path.Combine(LocalRoot, "probe.txt");

    /// <summary>建目录。settings.json 的父目录由 SettingsStore 自己建，这里只预建需要先存在的几个。</summary>
    public void EnsureDirectories()
    {
        Directory.CreateDirectory(RoamingRoot);
        Directory.CreateDirectory(Path.GetDirectoryName(HostsRules)!);
        Directory.CreateDirectory(Path.GetDirectoryName(ProxyLibrary)!);
        Directory.CreateDirectory(ProxyDirectory);
        Directory.CreateDirectory(LocalRoot);
        Directory.CreateDirectory(MediaDirectory);
        Directory.CreateDirectory(LogsDirectory);
    }
}
