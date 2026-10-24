using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;

namespace Toolbox.Core.Translation;

public sealed class TranslationException(string message) : Exception(message);

public sealed record TranslationResult(string Text, string? DetectedLanguage, TranslationEngine Engine);

internal static class JsonElementExtensions
{
    /// <summary>
    /// 引擎返回的数字字段有时是**字符串**（实测 MyMemory 的 responseStatus 会变成 "200"），
    /// 直接 TryGetInt32 会抛 InvalidOperationException 并让整次翻译失败。
    /// </summary>
    public static int? ToInt32OrNull(this JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Number => element.TryGetInt32(out var number) ? number : null,
        JsonValueKind.String when int.TryParse(element.GetString(), out var number) => number,
        _ => null,
    };
}

public interface ITranslator
{
    TranslationEngine Engine { get; }
    Task<TranslationResult> TranslateAsync(string text, string? source, string target, CancellationToken ct);
}

/// <summary>auto 只给需要翻墙的域名套代理；有道/MyMemory/国内 AI 直连。</summary>
public static class TranslationNetworkPolicy
{
    private static readonly string[] DirectHosts =
    {
        "youdao.com", "mymemory.translated.net",
        "api.deepseek.com", "dashscope.aliyuncs.com",
        "open.bigmodel.cn", "api.moonshot.cn", "api.siliconflow.cn",
    };

    public static int? ProxyPortFor(string host, TranslationSettings settings) => settings.Network switch
    {
        TranslationNetwork.Direct => null,
        TranslationNetwork.Proxy => settings.ProxyPort,
        _ => DirectHosts.Any(d => host.Equals(d, StringComparison.OrdinalIgnoreCase) ||
                                  host.EndsWith("." + d, StringComparison.OrdinalIgnoreCase))
            ? null
            : settings.ProxyPort,
    };

    public static string HostOf(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) ? uri.Host : url;
}

public interface IHttpClientProvider
{
    HttpClient Get(string host, TranslationSettings settings);
}

/// <summary>按 host + 网络设置复用 HttpClient；不随请求重建连接池。</summary>
public sealed class HttpClientProvider : IHttpClientProvider, IDisposable
{
    private readonly Dictionary<string, HttpClient> _clients = new();

    public HttpClient Get(string host, TranslationSettings settings)
    {
        var port = TranslationNetworkPolicy.ProxyPortFor(host, settings);
        var key = port?.ToString() ?? "direct";
        if (_clients.TryGetValue(key, out var existing)) return existing;

        var handler = new SocketsHttpHandler
        {
            UseProxy = port.HasValue,
            Proxy = port.HasValue ? new WebProxy($"http://127.0.0.1:{port}") : null,
            ConnectTimeout = TimeSpan.FromSeconds(10),
        };
        var client = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(Math.Clamp(settings.TimeoutSeconds, 3, 120)),
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36");
        _clients[key] = client;
        return client;
    }

    public void Dispose()
    {
        foreach (var client in _clients.Values) client.Dispose();
        _clients.Clear();
    }
}

public static class TranslatorFactory
{
    public static ITranslator? Create(TranslationEngine engine, TranslationSettings settings,
        IHttpClientProvider clients, string? aiKey)
    {
        return engine switch
        {
            TranslationEngine.Youdao => new YoudaoTranslator(
                clients.Get("aidemo.youdao.com", settings)),
            TranslationEngine.MyMemory => new MyMemoryTranslator(
                clients.Get("api.mymemory.translated.net", settings)),
            TranslationEngine.Google => new GoogleTranslator(
                clients.Get("translate.googleapis.com", settings)),
            TranslationEngine.Ai => new AiTranslator(
                clients.Get(TranslationNetworkPolicy.HostOf(settings.AiBaseUrl), settings),
                settings.AiBaseUrl, settings.AiModel, aiKey),
            _ => null,
        };
    }
}

public sealed class TranslationService : IDisposable
{
    private readonly IHttpClientProvider _clients;
    private readonly string? _aiKey;

    public TranslationService(IHttpClientProvider? clients = null, string? aiKey = null)
    {
        _clients = clients ?? new HttpClientProvider();
        _aiKey = aiKey;
    }

    public async Task<TranslationResult> TranslateAsync(string text, string? source,
        TranslationSettings settings, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(text)) throw new TranslationException("没有可翻译的文本");

        var target = source is null ? settings.TargetLanguage
            : TranslationLanguages.EffectiveTarget(source, settings.TargetLanguage);

        if (settings.Engine == TranslationEngine.Auto)
        {
            var errors = new List<string>();
            foreach (var engine in new[] { TranslationEngine.Youdao, TranslationEngine.MyMemory })
            {
                try
                {
                    return await RunAsync(engine, text, source, target, settings, ct);
                }
                catch (TranslationException ex)
                {
                    errors.Add($"{engine.ShortLabel()}：{ex.Message}");
                }
            }
            throw new TranslationException(string.Join("；", errors));
        }

        return await RunAsync(settings.Engine, text, source, target, settings, ct);
    }

    private async Task<TranslationResult> RunAsync(TranslationEngine engine, string text, string? source,
        string target, TranslationSettings settings, CancellationToken ct)
    {
        var translator = TranslatorFactory.Create(engine, settings, _clients, _aiKey)
            ?? throw new TranslationException("这个引擎在 Windows 版不可用");
        return await translator.TranslateAsync(text, source, target, ct);
    }

    public void Dispose() => (_clients as IDisposable)?.Dispose();
}

public sealed class YoudaoTranslator(HttpClient client) : ITranslator
{
    public TranslationEngine Engine => TranslationEngine.Youdao;

    public async Task<TranslationResult> TranslateAsync(string text, string? source, string target, CancellationToken ct)
    {
        var form = new Dictionary<string, string>
        {
            ["q"] = text,
            ["from"] = source is null ? "auto" : TranslationLanguages.YoudaoCode(source),
            ["to"] = TranslationLanguages.YoudaoCode(target),
        };
        using var response = await client.PostAsync("https://aidemo.youdao.com/trans",
            new FormUrlEncodedContent(form), ct);
        EnsureSuccess(response);

        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
        var root = doc.RootElement;
        if (root.TryGetProperty("errorCode", out var code) &&
            code.ToInt32OrNull() is { } errorCode && errorCode != 0)
            throw new TranslationException($"接口拒绝：错误码 {errorCode}");
        if (!root.TryGetProperty("translation", out var parts) || parts.ValueKind != JsonValueKind.Array)
            throw new TranslationException("接口返回了无法解析的数据");

        var translated = string.Concat(parts.EnumerateArray().Select(p => p.GetString()));
        if (translated.Length == 0) throw new TranslationException("接口返回了无法解析的数据");

        string? detected = null;
        if (root.TryGetProperty("l", out var pair) && pair.GetString() is { } pairText)
        {
            var src = pairText.Split('2')[0];
            detected = src.Length == 0 ? null : src;
        }
        return new TranslationResult(translated, detected, TranslationEngine.Youdao);
    }

    internal static void EnsureSuccess(HttpResponseMessage response)
    {
        if (!response.IsSuccessStatusCode)
            throw new TranslationException($"接口返回 HTTP {(int)response.StatusCode}");
    }
}

public sealed class MyMemoryTranslator(HttpClient client) : ITranslator
{
    public TranslationEngine Engine => TranslationEngine.MyMemory;

    public async Task<TranslationResult> TranslateAsync(string text, string? source, string target, CancellationToken ct)
    {
        var src = TranslationLanguages.WebCode(
            source ?? TranslationLanguages.GuessSource(text));
        var url = "https://api.mymemory.translated.net/get?q=" + Uri.EscapeDataString(text) +
                  "&langpair=" + Uri.EscapeDataString($"{src}|{TranslationLanguages.WebCode(target)}");
        using var response = await client.GetAsync(url, ct);
        YoudaoTranslator.EnsureSuccess(response);

        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
        var root = doc.RootElement;
        if (root.TryGetProperty("responseStatus", out var status) &&
            status.ToInt32OrNull() is { } statusCode && statusCode != 200)
        {
            var detail = root.TryGetProperty("responseDetails", out var d) ? d.GetString() : null;
            throw new TranslationException($"接口拒绝：{detail ?? $"状态 {statusCode}"}");
        }
        if (!root.TryGetProperty("responseData", out var data) ||
            !data.TryGetProperty("translatedText", out var translatedElement) ||
            translatedElement.GetString() is not { } translated)
            throw new TranslationException("接口返回了无法解析的数据");

        return new TranslationResult(DecodeEntities(translated), src, TranslationEngine.MyMemory);
    }

    /// <summary>MyMemory 会返回 HTML 实体，先还原再展示。</summary>
    internal static string DecodeEntities(string s) => s
        .Replace("&quot;", "\"")
        .Replace("&#39;", "'")
        .Replace("&apos;", "'")
        .Replace("&lt;", "<")
        .Replace("&gt;", ">")
        .Replace("&nbsp;", " ")
        .Replace("&amp;", "&");
}

public sealed class GoogleTranslator(HttpClient client) : ITranslator
{
    public TranslationEngine Engine => TranslationEngine.Google;

    public async Task<TranslationResult> TranslateAsync(string text, string? source, string target, CancellationToken ct)
    {
        var url = "https://translate.googleapis.com/translate_a/single?client=gtx" +
                  "&sl=" + Uri.EscapeDataString(source is null ? "auto" : TranslationLanguages.WebCode(source)) +
                  "&tl=" + Uri.EscapeDataString(TranslationLanguages.WebCode(target)) +
                  "&dt=t&q=" + Uri.EscapeDataString(text);
        using var response = await client.GetAsync(url, ct);
        YoudaoTranslator.EnsureSuccess(response);
        var body = await response.Content.ReadAsStringAsync(ct);

        JsonDocument doc;
        try { doc = JsonDocument.Parse(body); }
        catch (JsonException)
        {
            throw new TranslationException("Google 接口被拦截（返回的不是 JSON）。国内请配置代理或改用其他引擎。");
        }

        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Array || root.GetArrayLength() == 0 ||
                root[0].ValueKind != JsonValueKind.Array)
                throw new TranslationException("接口返回了无法解析的数据");

            var builder = new StringBuilder();
            foreach (var segment in root[0].EnumerateArray())
            {
                if (segment.ValueKind == JsonValueKind.Array && segment.GetArrayLength() > 0 &&
                    segment[0].GetString() is { } part)
                    builder.Append(part);
            }
            if (builder.Length == 0) throw new TranslationException("接口返回了无法解析的数据");

            var detected = root.GetArrayLength() > 2 && root[2].ValueKind == JsonValueKind.String
                ? root[2].GetString()
                : null;
            return new TranslationResult(builder.ToString(), detected, TranslationEngine.Google);
        }
    }
}

public sealed class AiTranslator(HttpClient client, string baseUrl, string model, string? apiKey) : ITranslator
{
    public TranslationEngine Engine => TranslationEngine.Ai;

    public async Task<TranslationResult> TranslateAsync(string text, string? source, string target, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(apiKey))
            throw new TranslationException("AI 引擎还没填 API Key（设置 › 翻译）");

        var root = baseUrl.EndsWith('/') ? baseUrl : baseUrl + "/";
        if (!Uri.TryCreate(root + "chat/completions", UriKind.Absolute, out var uri))
            throw new TranslationException("AI 接口地址无效");

        var targetName = TranslationLanguages.Label(target);
        var payload = new
        {
            model,
            temperature = 0.2,
            messages = new object[]
            {
                new
                {
                    role = "system",
                    content = "You are a professional translation engine. Translate into " + targetName +
                              ". Preserve formatting, names and code. Output only the translation, no explanations.",
                },
                new { role = "user", content = text },
            },
        };

        using var request = new HttpRequestMessage(HttpMethod.Post, uri)
        {
            Content = JsonContent.Create(payload),
        };
        request.Headers.Authorization = new("Bearer", apiKey);
        using var response = await client.SendAsync(request, ct);
        YoudaoTranslator.EnsureSuccess(response);

        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
        var body = doc.RootElement;
        if (body.TryGetProperty("error", out var error) &&
            error.TryGetProperty("message", out var message) && message.GetString() is { } errorText)
            throw new TranslationException($"接口拒绝：{errorText}");
        if (!body.TryGetProperty("choices", out var choices) || choices.ValueKind != JsonValueKind.Array ||
            choices.GetArrayLength() == 0 ||
            !choices[0].TryGetProperty("message", out var msg) ||
            !msg.TryGetProperty("content", out var content) ||
            content.GetString() is not { } translated)
            throw new TranslationException("接口返回了无法解析的数据");

        translated = translated.Trim();
        if (translated.Length == 0) throw new TranslationException("接口返回了无法解析的数据");
        return new TranslationResult(translated, source, TranslationEngine.Ai);
    }
}
