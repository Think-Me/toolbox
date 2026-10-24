namespace Toolbox.Core.Translation;

public static class TranslationLanguages
{
    public static readonly IReadOnlyList<(string Code, string Label)> Targets = new[]
    {
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"),
        ("ja", "日本語"), ("ko", "한국어"), ("fr", "Français"), ("de", "Deutsch"),
        ("es", "Español"), ("ru", "Русский"), ("it", "Italiano"), ("pt", "Português"),
        ("ar", "العربية"), ("th", "ไทย"), ("vi", "Tiếng Việt"),
    };

    public static string Label(string code) =>
        Targets.FirstOrDefault(t => t.Code == code).Label ?? code;

    /// <summary>有道：zh-Hans → zh-CHS，zh-Hant → zh-CHT，其余原样。</summary>
    public static string YoudaoCode(string code) => code switch
    {
        "zh-Hans" => "zh-CHS",
        "zh-Hant" => "zh-CHT",
        _ => code,
    };

    /// <summary>Google / MyMemory 用 zh-CN / zh-TW。</summary>
    public static string WebCode(string code) => code switch
    {
        "zh-Hans" => "zh-CN",
        "zh-Hant" => "zh-TW",
        _ => code,
    };

    public static string Primary(string code) => code.Split('-')[0];

    /// <summary>只为不支持 auto 的引擎挑源语言，不做统计推断。</summary>
    public static string GuessSource(string text)
    {
        foreach (var c in text)
        {
            var v = (int)c;
            if (v is >= 0x3040 and <= 0x30FF) return "ja";
            if (v is >= 0xAC00 and <= 0xD7AF) return "ko";
            if (v is >= 0x4E00 and <= 0x9FFF) return "zh-Hans";
            if (v is >= 0x0400 and <= 0x04FF) return "ru";
            if (v is >= 0x0E00 and <= 0x0E7F) return "th";
            if (v is >= 0x0600 and <= 0x06FF) return "ar";
        }
        return "en";
    }

    /// <summary>源语言撞上目标语言时换向；简↔繁不算撞车。</summary>
    public static string EffectiveTarget(string source, string target)
    {
        if (Primary(source) != Primary(target)) return target;
        if (Primary(target) == "zh" && source != target) return target;
        return Primary(target) == "en" ? "zh-Hans" : "en";
    }
}
