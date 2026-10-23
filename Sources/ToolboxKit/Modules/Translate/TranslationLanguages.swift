import Foundation

/// 目标语言表 + 各引擎的语言码差异。
/// 全部内部用 BCP-47（zh-Hans），只在请求时转成各家要的写法。
public enum TranslationLanguages {
    public static let targets: [(code: String, label: String)] = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"),
        ("ja", "日本語"), ("ko", "한국어"), ("fr", "Français"), ("de", "Deutsch"),
        ("es", "Español"), ("ru", "Русский"), ("it", "Italiano"), ("pt", "Português"),
        ("ar", "العربية"), ("th", "ไทย"), ("vi", "Tiếng Việt"),
    ]

    public static func label(for code: String) -> String {
        targets.first { $0.code == code }?.label ?? code
    }

    /// 有道：zh-Hans → zh-CHS；其余原样
    public static func youdaoCode(for code: String) -> String {
        switch code {
        case "zh-Hans": return "zh-CHS"
        case "zh-Hant": return "zh-CHT"
        default: return code
        }
    }

    /// Google / MyMemory 用 zh-CN / zh-TW
    public static func webCode(for code: String) -> String {
        switch code {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        default: return code
        }
    }

    /// 去掉地区后的主语言，用于比较"源 == 目标"
    public static func primary(_ code: String) -> String {
        String(code.split(separator: "-").first ?? Substring(code))
    }

    /// 本地轻量识别：只为那些不支持 auto 的引擎挑一个源语言。
    /// 不做统计推断 —— 目标场景是"英文网页偶尔夹中日韩"。
    public static func guessSource(_ text: String) -> String {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return "ja" }
        if scalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) }) { return "ko" }
        if scalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { return "zh-Hans" }
        if scalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) { return "ru" }
        if scalars.contains(where: { (0x0E00...0x0E7F).contains($0.value) }) { return "th" }
        if scalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) { return "ar" }
        return "en"
    }

    /// 源语言和目标语言撞车时自动换向，否则"英→英"会翻出原文。
    /// 简↔繁不算撞车：这是用户真实会要的转换，保持目标不变。
    public static func effectiveTarget(source: String, target: String) -> String {
        guard primary(source) == primary(target) else { return target }
        if primary(target) == "zh", source != target { return target }
        return primary(target) == "en" ? "zh-Hans" : "en"
    }
}
