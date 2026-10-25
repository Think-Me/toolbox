using System.IO.Compression;
using System.Text.Json;

namespace Toolbox.Core.Proxy;

/// <summary>
/// xray 内核 / geoip·geosite 规则库的更新检查与应用。
/// 端点固定为官方 GitHub release。规则库用 Loyalsoldier/v2ray-rules-dat
/// （v2rayN 同源），xray 用 XTLS/Xray-core。
/// </summary>
public static class ProxyAssetUpdate
{
    public const string XrayApi = "https://api.github.com/repos/XTLS/Xray-core/releases/latest";
    public const string RulesApi = "https://api.github.com/repos/Loyalsoldier/v2ray-rules-dat/releases/latest";
    public const string RulesVersionStamp = "rules-version";

    /// <summary>Windows 64 位的内核 zip 资产名。</summary>
    public const string WindowsAsset = "Xray-windows-64.zip";

    public static Uri XrayZip(string tag) =>
        new($"https://github.com/XTLS/Xray-core/releases/download/{tag}/{WindowsAsset}");

    public static Uri RulesFile(string tag, string name) =>
        new($"https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/{tag}/{name}");

    /// <summary>latest 别名：不查版本号直接拉最新规则（首次播种用）。</summary>
    public static Uri LatestRulesFile(string name) =>
        new($"https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/{name}");

    /// <summary>从 GitHub release JSON 里取 tag_name（纯函数，可测）。</summary>
    public static string? TagFromReleaseJson(byte[] data)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            return doc.RootElement.TryGetProperty("tag_name", out var tag) &&
                   tag.ValueKind == JsonValueKind.String
                ? tag.GetString()
                : null;
        }
        catch
        {
            return null;
        }
    }

    public static (string Core, string? Rules) CurrentVersions(string proxyDirectory)
    {
        string Read(string name)
        {
            try
            {
                var path = Path.Combine(proxyDirectory, name);
                return File.Exists(path) ? File.ReadAllText(path).Trim() : "";
            }
            catch
            {
                return "";
            }
        }

        return (Read(XrayBootstrap.CoreStampName).Length > 0 ? Read(XrayBootstrap.CoreStampName) : "未知",
            Read(RulesVersionStamp) is { Length: > 0 } rules ? rules : null);
    }

    /// <summary>latest tag 检查（网络）。任一失败返回 null，不阻断另一个。</summary>
    public static (string? CoreLatest, string? RulesLatest) CheckLatest(Func<string, byte[]> get)
    {
        string? TagOf(string url)
        {
            try { return TagFromReleaseJson(get(url)); }
            catch { return null; }
        }
        return (TagOf(XrayApi), TagOf(RulesApi));
    }

    /// <summary>
    /// geo 规则缺失时自动播种（xray 的路由规则引用 geoip:private / geosite:cn，
    /// 缺文件直接起不来）。走 latest 别名 URL，不依赖版本查询。
    /// </summary>
    public static void EnsureRules(string proxyDirectory, Func<Uri, byte[]> download)
    {
        var missing = XrayBootstrap.RuleFiles
            .Where(name => !File.Exists(Path.Combine(proxyDirectory, name)))
            .ToList();
        if (missing.Count == 0) return;

        foreach (var name in missing)
        {
            var data = download(LatestRulesFile(name));
            File.WriteAllBytes(Path.Combine(proxyDirectory, name), data);
        }
        File.WriteAllText(Path.Combine(proxyDirectory, RulesVersionStamp), "latest");
    }

    /// <summary>
    /// 更新规则库：下载最新 geoip.dat + geosite.dat 覆盖到工作目录，写版本戳。
    /// </summary>
    public static void ApplyRulesUpdate(string tag, string proxyDirectory,
                                        Func<Uri, byte[]> download)
    {
        var tmp = Path.Combine(Path.GetTempPath(), $"toolbox-rules-{Guid.NewGuid():N}");
        try
        {
            Directory.CreateDirectory(tmp);
            foreach (var name in XrayBootstrap.RuleFiles)
            {
                var data = download(RulesFile(tag, name));
                File.WriteAllBytes(Path.Combine(tmp, name), data);
            }
            foreach (var name in XrayBootstrap.RuleFiles)
                File.Copy(Path.Combine(tmp, name), Path.Combine(proxyDirectory, name), overwrite: true);
            File.WriteAllText(Path.Combine(proxyDirectory, RulesVersionStamp), tag);
        }
        finally
        {
            try { Directory.Delete(tmp, recursive: true); } catch { /* 清理失败无所谓 */ }
        }
    }

    /// <summary>
    /// 更新内核：下载 zip、解压出 xray.exe、覆盖工作目录。
    /// 运行中的 xray 进程持有旧文件时 Windows 不允许覆盖 —— 调用方必须先停内核再更新。
    /// </summary>
    public static void ApplyCoreUpdate(string tag, string proxyDirectory, Func<Uri, byte[]> download)
    {
        var tmp = Path.Combine(Path.GetTempPath(), $"toolbox-xray-{Guid.NewGuid():N}");
        try
        {
            Directory.CreateDirectory(tmp);
            var zip = Path.Combine(tmp, "xray.zip");
            File.WriteAllBytes(zip, download(XrayZip(tag)));
            ZipFile.ExtractToDirectory(zip, tmp, overwriteFiles: true);

            var exe = Path.Combine(tmp, "xray", "xray.exe");
            if (!File.Exists(exe)) exe = Path.Combine(tmp, "xray.exe");
            if (!File.Exists(exe)) throw new InvalidOperationException("zip 里没有 xray.exe");

            File.Copy(exe, Path.Combine(proxyDirectory, XrayBootstrap.CoreExe), overwrite: true);
            File.WriteAllText(Path.Combine(proxyDirectory, XrayBootstrap.CoreStampName), tag);
        }
        finally
        {
            try { Directory.Delete(tmp, recursive: true); } catch { /* 清理失败无所谓 */ }
        }
    }
}
