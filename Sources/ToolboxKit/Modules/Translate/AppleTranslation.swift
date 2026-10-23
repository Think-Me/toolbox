import Foundation

#if canImport(Translation)
import Translation
#endif

/// Apple 本地翻译能力探测。
///
/// 为什么要单独包一层：`Translation.framework` 是 macOS 15 才有的，
/// 而本 App 的部署目标是 14。所有 Apple 相关符号都必须藏在 `#available` 里，
/// 让 14 上的代码路径退化成"不可用 → 自动改用有道"。
public enum AppleTranslationAvailability {
    /// 必须传具体源语言：`source: nil`（让框架自己识别）在短句/混合文本上会直接报
    /// "The language could not be automatically detected"，实测每次热键都会弹这个错。
    public static func supports(source: String, target: String) async -> Bool {
        guard #available(macOS 15.0, *) else { return false }
        #if canImport(Translation)
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: target))
        return status != .unsupported
        #else
        return false
        #endif
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
public enum AppleTranslationConfiguration {
    public static func make(source: String, target: String) -> TranslationSession.Configuration {
        TranslationSession.Configuration(source: Locale.Language(identifier: source),
                                         target: Locale.Language(identifier: target))
    }
}
#endif
