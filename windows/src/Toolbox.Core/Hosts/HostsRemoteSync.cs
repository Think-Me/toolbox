using System.Net;
using System.Net.Http;

namespace Toolbox.Core.Hosts;

public enum RemoteSyncError
{
    BadUrl,
    Http,
    Timeout,
    TooLarge,
    Undecodable,
    Network,
}

/// <summary>一次抓取的结果。NotModified = 304，缓存仍然有效。</summary>
public sealed record RemoteFetchResult(
    string? Content,
    string? ETag,
    bool NotModified,
    RemoteSyncError? Error = null,
    int? HttpStatus = null)
{
    public static RemoteFetchResult Ok(string content, string? etag) => new(content, etag, false);

    public static RemoteFetchResult Unchanged(string? etag) => new(null, etag, true);

    public static RemoteFetchResult Fail(RemoteSyncError error, int? status = null) =>
        new(null, null, false, error, status);
}

public interface IRemoteFetcher
{
    RemoteFetchResult Fetch(string url, string? etag);
}

/// <summary>
/// ETag 条件请求 + 超时 + 体积上限。Remote 规则的内容是别人服务器上的 hosts 文件，
/// 上限挡住"被喂一个 500MB 的文件"这种事。
/// </summary>
public sealed class HttpRemoteFetcher : IRemoteFetcher
{
    public const int MaxBytes = 2 * 1024 * 1024;
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(15);

    private readonly TimeSpan _timeout;

    public HttpRemoteFetcher() : this(DefaultTimeout) { }

    public HttpRemoteFetcher(TimeSpan timeout) => _timeout = timeout;

    public RemoteFetchResult Fetch(string url, string? etag)
    {
        // 只收 http(s)：file:// / ftp:// 一律不进
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
            uri.Scheme is not ("http" or "https"))
            return RemoteFetchResult.Fail(RemoteSyncError.BadUrl);

        try
        {
            using var client = new HttpClient { Timeout = _timeout };
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            if (!string.IsNullOrEmpty(etag)) request.Headers.TryAddWithoutValidation("If-None-Match", etag);

            using var response = client.Send(request);
            if (response.StatusCode == HttpStatusCode.NotModified)
                return RemoteFetchResult.Unchanged(etag);

            if (!response.IsSuccessStatusCode)
                return RemoteFetchResult.Fail(RemoteSyncError.Http, (int)response.StatusCode);

            var bytes = response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult();
            if (bytes.Length > MaxBytes)
                return RemoteFetchResult.Fail(RemoteSyncError.TooLarge, (int)response.StatusCode);

            // hosts 文件可能出现 BOM / GBK，这里按 UTF-8 宽容解码；坏字节不抛异常
            var text = new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false,
                throwOnInvalidBytes: false).GetString(bytes);
            return RemoteFetchResult.Ok(text, response.Headers.ETag?.Tag);
        }
        catch (TaskCanceledException)
        {
            return RemoteFetchResult.Fail(RemoteSyncError.Timeout);
        }
        catch (HttpRequestException)
        {
            return RemoteFetchResult.Fail(RemoteSyncError.Network);
        }
        catch (Exception)
        {
            return RemoteFetchResult.Fail(RemoteSyncError.Undecodable);
        }
    }
}

public enum RemoteSyncOutcome
{
    /// <summary>抓到新内容，规则缓存已更新。</summary>
    Updated,
    /// <summary>304：服务器确认内容没变，缓存继续用。</summary>
    NotModified,
    /// <summary>拉取失败但有缓存：继续用缓存参与编译，离线不该让规则失效。</summary>
    UsedCache,
    /// <summary>失败且没有缓存，这条规则这次等于空内容。</summary>
    Failed,
}

/// <summary>
/// 远程规则同步：把抓取结果写回规则字段。判定逻辑（怎么更新缓存 / 什么时候回退缓存）
/// 和 HTTP 细节分开，前者可以纯单测。
/// </summary>
public static class HostsRemoteSync
{
    public static RemoteSyncOutcome Sync(HostsRule rule, IRemoteFetcher fetcher) =>
        Apply(rule, fetcher.Fetch(rule.Source, rule.ETag));

    public static RemoteSyncOutcome Apply(HostsRule rule, RemoteFetchResult result)
    {
        rule.LastSyncAt = DateTimeOffset.Now;

        if (result.NotModified)
        {
            rule.LastError = null;
            return RemoteSyncOutcome.NotModified;
        }

        if (result.Error is { } error)
        {
            rule.LastError = Describe(error, result.HttpStatus);
            if (!string.IsNullOrEmpty(rule.CachedContent))
                return RemoteSyncOutcome.UsedCache;

            // 没有缓存可用：这次编译这条规则就是空内容，不能拿旧值装新鲜
            rule.CachedContent = null;
            return RemoteSyncOutcome.Failed;
        }

        rule.CachedContent = result.Content;
        rule.ETag = result.ETag;
        rule.LastError = null;
        return RemoteSyncOutcome.Updated;
    }

    public static string Describe(RemoteSyncError error, int? status) => error switch
    {
        RemoteSyncError.BadUrl => "URL 无效（只支持 http/https）",
        RemoteSyncError.Http => status is { } code ? $"服务器返回 {code}" : "服务器返回错误",
        RemoteSyncError.Timeout => "请求超时",
        RemoteSyncError.TooLarge => $"内容超过 {HttpRemoteFetcher.MaxBytes / 1024 / 1024}MB 上限",
        RemoteSyncError.Network => "网络不可达",
        _ => "响应无法解析",
    };
}
