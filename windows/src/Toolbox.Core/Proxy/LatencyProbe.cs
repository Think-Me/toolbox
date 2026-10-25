using System.Diagnostics;
using System.Net;

namespace Toolbox.Core.Proxy;

/// <summary>
/// 经本地 HTTP 代理发一次真实请求测延迟。
/// 用 HTTP 而不是 SOCKS：HttpClient 走 SOCKS 需要本地先解析域名再交给代理，
/// 被污染的 DNS 会让「代理明明是通的」却测出失败。HTTP 代理的 CONNECT 带域名，
/// 由 xray 远端解析。
/// </summary>
public static class LatencyProbe
{
    /// <summary>默认打一个 204 端点（无 body、快、只测通路）。</summary>
    public static readonly Uri DefaultUrl = new("https://www.gstatic.com/generate_204");

    public static HttpClient CreateClient(int httpPort, TimeSpan timeout)
    {
        return new HttpClient(new SocketsHttpHandler
        {
            Proxy = new WebProxy("127.0.0.1", httpPort),
            UseProxy = true,
            ConnectTimeout = timeout,
        })
        {
            Timeout = timeout,
            DefaultRequestHeaders = { { "Cache-Control", "no-cache" } },
        };
    }

    /// <summary>经 HTTP 代理请求 url，返回耗时（ms）或失败原因。</summary>
    public static (bool Ok, string Detail) MeasureThroughProxy(
        int httpPort, Uri? url = null, int timeoutSeconds = 5)
    {
        url ??= DefaultUrl;
        using var client = CreateClient(httpPort, TimeSpan.FromSeconds(timeoutSeconds));
        var start = Stopwatch.StartNew();
        try
        {
            using var response = client.GetAsync(url).GetAwaiter().GetResult();
            var ms = (int)start.ElapsedMilliseconds;
            return (int)response.StatusCode >= 400
                ? (false, $"HTTP {(int)response.StatusCode}")
                : (true, $"{ms} ms");
        }
        catch (Exception error)
        {
            return (false, error.Message);
        }
    }
}
