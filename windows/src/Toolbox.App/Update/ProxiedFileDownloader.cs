using System.IO;
using System.Net;
using System.Net.Http;

namespace Velopack.Sources;

/// <summary>
/// 自定义 Velopack 文件下载器：把「检查/下载走本地代理」做进 UpdateManager 的实际下载层
/// （BUG-008，对齐 Mac 的 useProxy/proxyPort）。Velopack 自带的 HttpClientFileDownloader
/// 不接受自定义 HttpClient，只能自己实现接口。
/// </summary>
internal sealed class ProxiedFileDownloader : IFileDownloader
{
    private readonly HttpClient _client;

    public ProxiedFileDownloader(bool useProxy, int proxyPort)
    {
        var handler = new HttpClientHandler();
        if (useProxy)
        {
            handler.Proxy = new WebProxy($"http://127.0.0.1:{proxyPort}") { BypassProxyOnLocal = true };
            handler.UseProxy = true;
        }
        _client = new HttpClient(handler) { Timeout = TimeSpan.FromMinutes(10) };
    }

    public async Task<byte[]> DownloadBytes(string url, IDictionary<string, string>? headers = null, double timeout = 30)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (headers is not null)
            foreach (var kv in headers)
                request.Headers.TryAddWithoutValidation(kv.Key, kv.Value);
        using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseContentRead);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsByteArrayAsync();
    }

    public async Task<string> DownloadString(string url, IDictionary<string, string>? headers = null, double timeout = 30)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (headers is not null)
            foreach (var kv in headers)
                request.Headers.TryAddWithoutValidation(kv.Key, kv.Value);
        using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseContentRead);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsStringAsync();
    }

    public async Task DownloadFile(string url, string writeToPath, Action<int>? progress = null,
                                   IDictionary<string, string>? headers = null, double timeout = 30,
                                   CancellationToken cancelToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (headers is not null)
            foreach (var kv in headers)
                request.Headers.TryAddWithoutValidation(kv.Key, kv.Value);
        using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancelToken);
        response.EnsureSuccessStatusCode();

        var total = response.Content.Headers.ContentLength ?? -1;
        await using var source = await response.Content.ReadAsStreamAsync(cancelToken);
        await using var target = File.Create(writeToPath);

        var buffer = new byte[81920];
        long read = 0;
        int chunk;
        while ((chunk = await source.ReadAsync(buffer, cancelToken)) > 0)
        {
            await target.WriteAsync(buffer.AsMemory(0, chunk), cancelToken);
            read += chunk;
            if (total > 0) progress?.Invoke((int)(read * 100 / total));
        }
    }

    public void Dispose() => _client.Dispose();
}
