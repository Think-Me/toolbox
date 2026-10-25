namespace Toolbox.Core.Proxy;

/// <summary>
/// 把 xray 内核 + geoip.dat + geosite.dat 从「随包目录」拷到可写工作目录。
///
/// 为什么不直接原地跑：xray 在 **config.json 同目录**找 geoip.dat，
/// 而 config.json 是运行时生成、必须落在可写目录。所以首启把三件套拷进
/// 工作目录，config 也生成在那儿。
///
/// Windows 上的「随包目录」= App 安装目录下的 `proxy\` 文件夹（用户手动放入
/// xray.exe / geoip.dat / geosite.dat / version.txt，或发布时一起打包）。
/// 更新策略（配合 ProxyAssetUpdate）：
/// - 内核：仅当缺失、或**随包版本比已装版本新**时才覆盖（数字段比较）。
///   这样运行时更新到更新的内核后，App 重启不会把它冲回旧版。
/// - 规则库 dat：仅当缺失时播种。之后由更新器独立更新，不受 App 版本影响。
/// </summary>
public static class XrayBootstrap
{
    public const string CoreExe = "xray.exe";
    public const string CoreStampName = ".xray-version";
    public const string BundledVersionName = "version.txt";
    public static readonly string[] RuleFiles = ["geoip.dat", "geosite.dat"];

    /// <summary>内核要不要覆盖：随包有货，且（缺失，或随包比已装新）。</summary>
    public static bool ShouldCopyCore(string? bundledVersion, string? onDiskVersion, bool present)
    {
        if (string.IsNullOrEmpty(bundledVersion)) return false;
        if (!present) return true;
        return ProxyVersion.IsNewer(bundledVersion, onDiskVersion);
    }

    /// <summary>规则库要不要播种：只在缺失时（更新交给更新器）。</summary>
    public static bool ShouldSeedRules(bool present) => !present;

    /// <summary>
    /// 确保工作目录里三件套就位。返回 xray.exe 的完整路径；失败抛 BootstrapException。
    /// </summary>
    public static string Ensure(string bundledDir, string workDir)
    {
        var bundledVersion = ReadTrimmed(Path.Combine(bundledDir, BundledVersionName));
        if (string.IsNullOrEmpty(bundledVersion))
            throw new BootstrapException("随包没有 xray 资产（version.txt 缺失）");

        Directory.CreateDirectory(workDir);
        var xrayPath = Path.Combine(workDir, CoreExe);
        var corePresent = File.Exists(xrayPath);
        var onDiskVersion = ReadTrimmed(Path.Combine(workDir, CoreStampName));

        if (ShouldCopyCore(bundledVersion, onDiskVersion, corePresent))
        {
            File.Copy(Path.Combine(bundledDir, CoreExe), xrayPath, overwrite: true);
            File.WriteAllText(Path.Combine(workDir, CoreStampName), bundledVersion);
        }

        if (ShouldSeedRules(RuleFiles.All(f => File.Exists(Path.Combine(workDir, f)))))
        {
            foreach (var name in RuleFiles)
            {
                var source = Path.Combine(bundledDir, name);
                if (!File.Exists(source)) continue;
                File.Copy(source, Path.Combine(workDir, name), overwrite: true);
            }
        }

        if (!File.Exists(xrayPath))
            throw new BootstrapException("工作目录里没有 xray.exe，且随包资产不可用");
        return xrayPath;
    }

    /// <summary>
    /// Windows 的取用顺序：工作目录里已有 xray.exe 就直接用（含用户手动放置/更新器下载）；
    /// 否则尝试从随包目录播种。
    /// </summary>
    public static string EnsureInstalled(string workDir, string? bundledDir)
    {
        if (File.Exists(Path.Combine(workDir, CoreExe))) return Path.Combine(workDir, CoreExe);
        if (bundledDir is not null && Directory.Exists(bundledDir)) return Ensure(bundledDir, workDir);
        throw new BootstrapException(
            $"没有找到 xray.exe（{workDir}）。可在代理面板里「更新内核」自动下载，或手动放入。");
    }

    private static string? ReadTrimmed(string path)
    {
        try
        {
            return File.Exists(path) ? File.ReadAllText(path).Trim() : null;
        }
        catch
        {
            return null;
        }
    }
}

public sealed class BootstrapException(string message) : Exception(message);
