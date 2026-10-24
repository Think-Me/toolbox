using System.Text.Json;
using System.Text.Json.Serialization;

namespace Toolbox.Core.Translation;

public enum TranslationEngine
{
    Auto,
    Youdao,
    MyMemory,
    Google,
    Ai,
}

public enum TranslationNetwork
{
    Auto,
    Direct,
    Proxy,
}

public static class TranslationEngineInfo
{
    public static string Label(this TranslationEngine engine) => engine switch
    {
        TranslationEngine.Auto => "自动（有道 → MyMemory）",
        TranslationEngine.Youdao => "有道（免费）",
        TranslationEngine.MyMemory => "MyMemory（免费）",
        TranslationEngine.Google => "Google（需代理）",
        TranslationEngine.Ai => "AI（需 Key）",
        _ => engine.ToString(),
    };

    public static string ShortLabel(this TranslationEngine engine) => engine switch
    {
        TranslationEngine.Auto => "自动",
        TranslationEngine.Youdao => "有道",
        TranslationEngine.MyMemory => "MyMemory",
        TranslationEngine.Google => "Google",
        TranslationEngine.Ai => "AI",
        _ => engine.ToString(),
    };
}

public sealed class TranslationSettings
{
    [JsonConverter(typeof(TranslationEngineConverter))]
    public TranslationEngine Engine { get; set; } = TranslationEngine.Auto;
    /// <summary>BCP-47：zh-Hans / zh-Hant / en / ja …</summary>
    public string TargetLanguage { get; set; } = "zh-Hans";
    [JsonConverter(typeof(TranslationNetworkConverter))]
    public TranslationNetwork Network { get; set; } = TranslationNetwork.Auto;
    /// <summary>走代理时的本地 HTTP 端口（xray 默认 10809）。</summary>
    public int ProxyPort { get; set; } = 10809;
    /// <summary>OpenAI 兼容接口。</summary>
    public string AiBaseUrl { get; set; } = "https://api.deepseek.com/v1";
    public string AiModel { get; set; } = "deepseek-chat";
    /// <summary>API Key 不放 settings.json，单独存 DPAPI 保护的 ai.key。</summary>
    [JsonIgnore]
    public string? AiApiKey { get; set; }
    public int TimeoutSeconds { get; set; } = 20;
}

/// <summary>老配置里出现未知引擎名（例如 macOS 的 apple）时回落 Auto，而不是整份设置解码失败。</summary>
public sealed class TranslationEngineConverter : JsonConverter<TranslationEngine>
{
    public override TranslationEngine Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.String &&
            Enum.TryParse<TranslationEngine>(reader.GetString(), true, out var parsed) &&
            Enum.IsDefined(parsed))
            return parsed;
        if (reader.TokenType == JsonTokenType.Number && reader.TryGetInt32(out var n) &&
            Enum.IsDefined(typeof(TranslationEngine), n))
            return (TranslationEngine)n;
        return TranslationEngine.Auto;
    }

    public override void Write(Utf8JsonWriter writer, TranslationEngine value, JsonSerializerOptions options)
        => writer.WriteStringValue(value.ToString());
}

public sealed class TranslationNetworkConverter : JsonConverter<TranslationNetwork>
{
    public override TranslationNetwork Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.String &&
            Enum.TryParse<TranslationNetwork>(reader.GetString(), true, out var parsed) &&
            Enum.IsDefined(parsed))
            return parsed;
        return TranslationNetwork.Auto;
    }

    public override void Write(Utf8JsonWriter writer, TranslationNetwork value, JsonSerializerOptions options)
        => writer.WriteStringValue(value.ToString());
}
