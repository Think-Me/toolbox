using System.Net;
using System.Net.Sockets;
using Xunit;
using Toolbox.Core.Hosts;

namespace Toolbox.Core.Tests;

public sealed class HostsRemoteSyncTests
{
    private static HostsRule NewRule(string url = "https://example.com/hosts", string? etag = null) => new()
    {
        Name = "远程规则",
        Kind = RuleKind.Remote,
        Source = url,
        ETag = etag,
    };

    // ---- 判定逻辑（stub fetcher，不碰网络） ----

    [Fact]
    public void UpdatedContentReplacesCacheAndStoresEtag()
    {
        var rule = NewRule(etag: "\"old\"");
        var outcome = HostsRemoteSync.Apply(rule, RemoteFetchResult.Ok("127.0.0.1 a.test", "\"v2\""));

        Assert.Equal(RemoteSyncOutcome.Updated, outcome);
        Assert.Equal("127.0.0.1 a.test", rule.CachedContent);
        Assert.Equal("\"v2\"", rule.ETag);
        Assert.Null(rule.LastError);
        Assert.NotNull(rule.LastSyncAt);
    }

    [Fact]
    public void NotModifiedKeepsCacheUntouched()
    {
        var rule = NewRule(etag: "\"v1\"");
        rule.CachedContent = "旧内容";

        var outcome = HostsRemoteSync.Apply(rule, RemoteFetchResult.Unchanged("\"v1\""));

        Assert.Equal(RemoteSyncOutcome.NotModified, outcome);
        Assert.Equal("旧内容", rule.CachedContent);
        Assert.Null(rule.LastError);
    }

    /// <summary>离线不该让规则失效：有缓存就继续用缓存参与编译。</summary>
    [Fact]
    public void FailureWithCacheFallsBackToCache()
    {
        var rule = NewRule();
        rule.CachedContent = "上次抓到的";

        var outcome = HostsRemoteSync.Apply(rule, RemoteFetchResult.Fail(RemoteSyncError.Timeout));

        Assert.Equal(RemoteSyncOutcome.UsedCache, outcome);
        Assert.Equal("上次抓到的", rule.CachedContent);
        Assert.Equal("请求超时", rule.LastError);
    }

    [Fact]
    public void FailureWithoutCacheClearsTheContent()
    {
        var rule = NewRule();

        var outcome = HostsRemoteSync.Apply(rule, RemoteFetchResult.Fail(RemoteSyncError.Http, 404));

        Assert.Equal(RemoteSyncOutcome.Failed, outcome);
        Assert.Null(rule.CachedContent);
        Assert.Equal("服务器返回 404", rule.LastError);
    }

    [Fact]
    public void SyncFetchesWithTheRuleUrlAndStoredEtag()
    {
        string? seenUrl = null;
        string? seenEtag = null;
        var fetcher = new StubFetcher((url, etag) =>
        {
            seenUrl = url;
            seenEtag = etag;
            return RemoteFetchResult.Ok("新内容", "\"v9\"");
        });
        var rule = NewRule(url: "https://example.com/h", etag: "\"v8\"");

        var outcome = HostsRemoteSync.Sync(rule, fetcher);

        Assert.Equal(RemoteSyncOutcome.Updated, outcome);
        Assert.Equal("https://example.com/h", seenUrl);
        Assert.Equal("\"v8\"", seenEtag);
        Assert.Equal("新内容", rule.CachedContent);
    }

    private sealed class StubFetcher(Func<string, string?, RemoteFetchResult> handler) : IRemoteFetcher
    {
        public RemoteFetchResult Fetch(string url, string? etag) => handler(url, etag);
    }

    // ---- HttpRemoteFetcher（本机起一个裸 TCP HTTP 服务，确定性验证） ----

    [Fact]
    public void HttpFetcherSendsIfNoneMatchAndHonors304()
    {
        using var server = new RawHttpServer();
        server.RespondWith = context =>
        {
            // 第二次请求（带 If-None-Match）回 304，第一次回 200 + ETag
            if (context.ContainsKey("if-none-match"))
                return ("304 Not Modified", new Dictionary<string, string>(), Array.Empty<byte>());
            return ("200 OK", new Dictionary<string, string> { ["ETag"] = "\"abc123\"" },
                "127.0.0.1 via.test"u8.ToArray());
        };

        var fetcher = new HttpRemoteFetcher(TimeSpan.FromSeconds(5));

        var first = fetcher.Fetch(server.Url, null);
        Assert.Null(first.Error);
        Assert.False(first.NotModified);
        Assert.Equal("127.0.0.1 via.test", first.Content);
        Assert.Equal("\"abc123\"", first.ETag);

        var second = fetcher.Fetch(server.Url, first.ETag);
        Assert.True(second.NotModified);
        Assert.Equal("\"abc123\"", second.ETag);
        // 服务端必须真的收到了 If-None-Match
        Assert.Equal("\"abc123\"", server.LastRequestHeaders["if-none-match"]);
    }

    [Fact]
    public void HttpFetcherRejectsNonHttpSchemesAndOversizedBodies()
    {
        var fetcher = new HttpRemoteFetcher(TimeSpan.FromSeconds(5));

        Assert.Equal(RemoteSyncError.BadUrl, fetcher.Fetch("file:///etc/hosts", null).Error);
        Assert.Equal(RemoteSyncError.BadUrl, fetcher.Fetch("不是URL", null).Error);

        using var server = new RawHttpServer();
        server.RespondWith = _ => ("200 OK", new Dictionary<string, string>(),
            new byte[HttpRemoteFetcher.MaxBytes + 1]);

        Assert.Equal(RemoteSyncError.TooLarge, fetcher.Fetch(server.Url, null).Error);
    }

    /// <summary>裸 TCP 最小 HTTP 服务：不依赖 HttpListener 的 URLACL 权限。</summary>
    private sealed class RawHttpServer : IDisposable
    {
        private readonly TcpListener _listener;
        private readonly CancellationTokenSource _stop = new();

        public Func<Dictionary<string, string>, (string Status, Dictionary<string, string> Headers, byte[] Body)> RespondWith
        {
            get => _respondWith;
            set
            {
                _respondWith = value;
                _serving ??= Task.Run(() => Serve(_stop.Token));
            }
        }

        private Func<Dictionary<string, string>, (string, Dictionary<string, string>, byte[])> _respondWith = null!;
        private Task? _serving;
        private TcpClient? _client;

        public Dictionary<string, string> LastRequestHeaders => _lastHeaders;
        private Dictionary<string, string> _lastHeaders = new();

        public string Url { get; }

        public RawHttpServer()
        {
            _listener = new TcpListener(IPAddress.Loopback, 0);
            _listener.Start();
            var port = ((IPEndPoint)_listener.LocalEndpoint).Port;
            Url = $"http://127.0.0.1:{port}/hosts";
        }

        private async Task Serve(CancellationToken token)
        {
            while (!token.IsCancellationRequested)
            {
                var client = await _listener.AcceptTcpClientAsync(token);
                _client = client;
                using var stream = client.GetStream();
                using var reader = new StreamReader(stream, leaveOpen: true);

                var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                var requestLine = await reader.ReadLineAsync(token);
                for (var line = await reader.ReadLineAsync(token);
                     line is not (null or "");
                     line = await reader.ReadLineAsync(token))
                {
                    var split = line.IndexOf(':');
                    if (split > 0) headers[line[..split].Trim()] = line[(split + 1)..].Trim();
                }
                _lastHeaders = headers;

                var (status, extra, body) = RespondWith(headers);
                var writer = new StreamWriter(stream, new System.Text.UTF8Encoding(false)) { AutoFlush = true };
                await writer.WriteAsync($"HTTP/1.1 {status}\r\nContent-Length: {body.Length}\r\nConnection: close\r\n");
                foreach (var (name, value) in extra) await writer.WriteAsync($"{name}: {value}\r\n");
                await writer.WriteAsync("\r\n");
                await stream.WriteAsync(body, token);
            }
        }

        public void Dispose()
        {
            _stop.Cancel();
            _client?.Dispose();
            _listener.Stop();
        }
    }
}
