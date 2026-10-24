using System.Net;
using System.Text;
using System.Text.Json;
using Toolbox.Core.Translation;
using Xunit;

namespace Toolbox.Core.Tests;

public sealed class TranslationTests
{
    private sealed class StubHandler(Func<HttpRequestMessage, string, HttpResponseMessage> respond)
        : HttpMessageHandler
    {
        public HttpRequestMessage? LastRequest { get; private set; }
        public string? LastBody { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken);
            LastRequest = request;
            LastBody = body;
            return respond(request, body);
        }
    }

    private sealed class SingleProvider(HttpClient client) : IHttpClientProvider
    {
        public HttpClient Get(string host, TranslationSettings settings) => client;
    }

    private static HttpClient Client(StubHandler handler) => new(handler);

    private static HttpResponseMessage Json(string body, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    [Fact]
    public void LanguageCodesMatchEachEngine()
    {
        Assert.Equal("zh-CHS", TranslationLanguages.YoudaoCode("zh-Hans"));
        Assert.Equal("zh-CHT", TranslationLanguages.YoudaoCode("zh-Hant"));
        Assert.Equal("ja", TranslationLanguages.YoudaoCode("ja"));
        Assert.Equal("zh-CN", TranslationLanguages.WebCode("zh-Hans"));
        Assert.Equal("zh-TW", TranslationLanguages.WebCode("zh-Hant"));
        Assert.Equal("ja", TranslationLanguages.GuessSource("こんにちは"));
        Assert.Equal("ko", TranslationLanguages.GuessSource("안녕하세요"));
        Assert.Equal("zh-Hans", TranslationLanguages.GuessSource("你好"));
        Assert.Equal("en", TranslationLanguages.GuessSource("hello"));
        Assert.Equal("zh-Hant", TranslationLanguages.EffectiveTarget("zh-Hans", "zh-Hant"));
        Assert.Equal("zh-Hans", TranslationLanguages.EffectiveTarget("en", "en"));
    }

    [Fact]
    public void AutoNetworkKeepsDomesticHostsDirect()
    {
        var settings = new TranslationSettings { Network = TranslationNetwork.Auto, ProxyPort = 10809 };
        Assert.Null(TranslationNetworkPolicy.ProxyPortFor("aidemo.youdao.com", settings));
        Assert.Null(TranslationNetworkPolicy.ProxyPortFor("api.mymemory.translated.net", settings));
        Assert.Equal(10809, TranslationNetworkPolicy.ProxyPortFor("translate.googleapis.com", settings));
        Assert.Equal(10809, TranslationNetworkPolicy.ProxyPortFor("api.openai.com", settings));

        settings.Network = TranslationNetwork.Direct;
        Assert.Null(TranslationNetworkPolicy.ProxyPortFor("translate.googleapis.com", settings));

        settings.Network = TranslationNetwork.Proxy;
        Assert.Equal(10809, TranslationNetworkPolicy.ProxyPortFor("aidemo.youdao.com", settings));
    }

    [Fact]
    public async Task YoudaoParsesTranslationAndDetectedLanguage()
    {
        var handler = new StubHandler((_, _) =>
            Json("""{"errorCode":0,"translation":["你好","世界"],"l":"en2zh-CHS"}"""));
        var translator = new YoudaoTranslator(Client(handler));

        var result = await translator.TranslateAsync("Hello world", null, "zh-Hans", default);

        Assert.Equal("你好世界", result.Text);
        Assert.Equal("en", result.DetectedLanguage);
        Assert.Equal(TranslationEngine.Youdao, result.Engine);
        Assert.Equal("https://aidemo.youdao.com/trans", handler.LastRequest!.RequestUri!.ToString());
        Assert.Contains("from=auto", handler.LastBody);
        Assert.Contains("to=zh-CHS", handler.LastBody);
        Assert.True(handler.LastBody!.Contains("q=Hello%20world") ||
                    handler.LastBody.Contains("q=Hello+world"));
    }

    [Fact]
    public async Task YoudaoRejectsNonZeroErrorCode()
    {
        var translator = new YoudaoTranslator(Client(new StubHandler((_, _) =>
            Json("""{"errorCode":411,"translation":[]}"""))));
        await Assert.ThrowsAsync<TranslationException>(() =>
            translator.TranslateAsync("hi", null, "zh-Hans", default));
    }

    [Fact]
    public async Task MyMemoryUsesGuessedSourceAndDecodesEntities()
    {
        var handler = new StubHandler((_, _) =>
            Json("""{"responseStatus":200,"responseData":{"translatedText":"Tom &amp; Jerry"}}"""));
        var translator = new MyMemoryTranslator(Client(handler));

        var result = await translator.TranslateAsync("Tom and Jerry", null, "zh-Hans", default);

        Assert.Equal("Tom & Jerry", result.Text);
        Assert.Equal("en", result.DetectedLanguage);
        Assert.Contains("langpair=en%7Czh-CN", handler.LastRequest!.RequestUri!.Query);
    }

    [Fact]
    public async Task GoogleParsesSegmentsAndRejectsHtml()
    {
        var handler = new StubHandler((_, _) => Json("""[[["你好","Hello",null,null,10]],null,"en"]"""));
        var translator = new GoogleTranslator(Client(handler));
        var result = await translator.TranslateAsync("Hello", null, "zh-Hans", default);
        Assert.Equal("你好", result.Text);
        Assert.Equal("en", result.DetectedLanguage);

        var blocked = new GoogleTranslator(Client(new StubHandler((_, _) =>
            new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("<html>Sorry…</html>", Encoding.UTF8, "text/html"),
            })));
        var error = await Assert.ThrowsAsync<TranslationException>(() =>
            blocked.TranslateAsync("Hello", null, "zh-Hans", default));
        Assert.Contains("被拦截", error.Message);
    }

    [Fact]
    public async Task AiPostsOpenAiCompatibleBodyAndNeedsKey()
    {
        var handler = new StubHandler((_, _) =>
            Json("""{"choices":[{"message":{"content":" 你好 "}}]}"""));
        var translator = new AiTranslator(Client(handler), "https://api.deepseek.com/v1",
            "deepseek-chat", "sk-test");

        var result = await translator.TranslateAsync("Hello", null, "zh-Hans", default);

        Assert.Equal("你好", result.Text);
        Assert.Equal("https://api.deepseek.com/v1/chat/completions",
            handler.LastRequest!.RequestUri!.ToString());
        Assert.Equal("Bearer sk-test", handler.LastRequest.Headers.Authorization!.ToString());
        using var body = JsonDocument.Parse(handler.LastBody!);
        Assert.Equal("deepseek-chat", body.RootElement.GetProperty("model").GetString());

        var noKey = new AiTranslator(Client(handler), "https://x/v1", "m", null);
        await Assert.ThrowsAsync<TranslationException>(() =>
            noKey.TranslateAsync("Hello", null, "zh-Hans", default));
    }

    [Fact]
    public async Task AutoFallsBackFromYoudaoToMyMemory()
    {
        var handler = new StubHandler((request, _) =>
            request.RequestUri!.Host == "aidemo.youdao.com"
                ? Json("""{"errorCode":411,"translation":[]}""")
                : Json("""{"responseStatus":200,"responseData":{"translatedText":"fallback"}}"""));
        var service = new TranslationService(new SingleProvider(Client(handler)));
        var settings = new TranslationSettings { Engine = TranslationEngine.Auto };

        var result = await service.TranslateAsync("Hello", null, settings);

        Assert.Equal("fallback", result.Text);
        Assert.Equal(TranslationEngine.MyMemory, result.Engine);
    }

    [Fact]
    public async Task ExplicitEngineIsNotRetried()
    {
        var handler = new StubHandler((_, _) => Json("""{"errorCode":411,"translation":[]}"""));
        var service = new TranslationService(new SingleProvider(Client(handler)));
        var settings = new TranslationSettings { Engine = TranslationEngine.Youdao };

        await Assert.ThrowsAsync<TranslationException>(() =>
            service.TranslateAsync("Hello", null, settings));
    }

    [Fact]
    public async Task EmptyInputIsRejectedBeforeAnyRequest()
    {
        var handler = new StubHandler((_, _) => Json("{}"));
        var service = new TranslationService(new SingleProvider(Client(handler)));

        await Assert.ThrowsAsync<TranslationException>(() =>
            service.TranslateAsync("   ", null, new TranslationSettings()));
        Assert.Null(handler.LastRequest);
    }
}
