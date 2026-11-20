namespace Toolbox.Core.Settings;

/// <summary>
/// 更新源 URL 的派生规则（BUG-008 纯逻辑，对齐 Mac AppUpdater.downloadURL 语义）。
///
/// 语义（与 macOS 版一致）：
///  - 加速镜像只作用于**下载 release 资产**（nupkg 等）；feed 探测（releases.win.json）
///    仍走代理或直连——镜像站常不代理 api/小文件，且探测流量极小，直连失败可接受。
///  - 镜像前缀以 / 结尾与否都接受，规范化为 "prefix + url"。
///  - 代理端口只对走镜像/直连都失败的场景兜底（HTTP 代理由 HttpClient 侧实现）。
/// </summary>
public static class UpdateFeed
{
    /// <summary>Velopack feed 文件名：updateUrl 目录下的 releases.win.json。</summary>
    public const string FeedFileName = "releases.win.json";

    /// <summary>feed 探测地址：直接用 updateUrl 拼上 feed 文件名（不走镜像）。</summary>
    public static string FeedUrl(string updateUrl)
    {
        if (string.IsNullOrWhiteSpace(updateUrl)) return "";
        var trimmed = updateUrl.TrimEnd('/');
        return $"{trimmed}/{FeedFileName}";
    }

    /// <summary>
    /// 资产下载地址：镜像为空时原样返回；非空时前缀镜像。
    /// （对齐 Mac AppUpdater.downloadURL(for:mirror:)。）
    /// </summary>
    public static string AssetDownloadUrl(string assetUrl, string mirror)
    {
        if (string.IsNullOrWhiteSpace(assetUrl)) return "";
        var m = (mirror ?? "").Trim();
        if (m.Length == 0) return assetUrl;
        var prefix = m.EndsWith("/") ? m : m + "/";
        return prefix + assetUrl;
    }

    /// <summary>代理端口有效性（1..65535，越界回落 10809 —— Mac 版 UI 用 Stepper 限不了手改 settings.json 的情况）。</summary>
    public static int NormalizeProxyPort(int port) =>
        port is >= 1 and <= 65535 ? port : 10809;

    /// <summary>检查间隔规范化：至少 1 小时，封顶 168（对齐 Mac 的 1...168 Stepper）。</summary>
    public static int NormalizeIntervalHours(int hours) => Math.Clamp(hours, 1, 168);
}
