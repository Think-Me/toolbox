import AppKit
import AVFoundation
import Foundation

/// 划词翻译的界面状态机：取词 → 选引擎 → 翻译 → 展示/复制/朗读/替换。
///
/// 为什么 Apple 本地那条路是"设置配置 + 等视图回调"而不是直接 await：
/// `TranslationSession` 只能由 SwiftUI 的 `.translationTask` 提供，无法在模型里构造。
/// 所以模型只负责把请求挂到 `appleConfiguration` 上，真正的 await 在视图里跑。
@MainActor
public final class TranslationModel: ObservableObject {
    /// 单次翻译上限。免费接口有长度限制，界面也不该被一整篇论文撑爆。
    public static let maxCharacters = 6000

    @Published public private(set) var sourceText = ""
    @Published public private(set) var output: String?
    @Published public private(set) var detectedLanguage: String?
    @Published public private(set) var isWorking = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var engineLabel = ""
    @Published public private(set) var targetLanguage = "zh-Hans"
    @Published public private(set) var copied = false

    /// SwiftUI 侧用；类型是 `Any?` 是因为 Translation 框架的 Configuration
    /// 只在 macOS 15 存在，而本文件要为 14 编译。
    @Published public var appleConfiguration: Any?
    /// 每请求自增，视图拿它当 `.id`，保证同一个语言对连续点"重译"也能再次触发
    @Published public private(set) var appleRequestID = 0
    public private(set) var applePendingText: String?

    private let settings: () -> TranslationSettings
    private let aiKey: () -> String?
    private var task: Task<Void, Never>?
    private let speech = AVSpeechSynthesizer()

    public init(settings: @escaping () -> TranslationSettings,
                aiKey: @escaping () -> String? = { KeychainStore.aiKey }) {
        self.settings = settings
        self.aiKey = aiKey
    }

    // MARK: 入口

    public func begin(text: String) {
        let clipped = String(text.prefix(Self.maxCharacters))
        sourceText = clipped
        copied = false
        retranslate()
    }

    public func retranslate() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            fail(TranslationError.emptyInput)
            return
        }
        task?.cancel()
        output = nil
        errorMessage = nil
        detectedLanguage = nil
        copied = false
        isWorking = true
        let s = settings()
        targetLanguage = s.targetLanguage
        task = Task { @MainActor [weak self] in
            await self?.perform(text, s)
        }
    }

    private func perform(_ text: String, _ s: TranslationSettings) async {
        // 本地先猜一下源语言：既用来避开"英→英"，也给 Apple 一个明确的 source。
        // Apple 的 source=nil（自动识别）在短句上会报 "could not be automatically detected"。
        let source = TranslationLanguages.guessSource(text)
        let target = TranslationLanguages.effectiveTarget(source: source, target: s.targetLanguage)
        targetLanguage = target
        var engines: [TranslationEngine]
        switch s.engine {
        case .auto:
            if await AppleTranslationAvailability.supports(source: source, target: target) {
                startApple(text: text, source: source, target: target)
                return
            }
            // 自动链：Apple 不可用 → 有道 → MyMemory。Google 不进链（国内几乎必被拦）。
            engines = [.youdao, .mymemory]
        case .apple:
            startApple(text: text, source: source, target: target)
            return
        default:
            engines = [s.engine]
        }

        var lastError: Error = TranslationError.message("没有可用的翻译引擎")
        for engine in engines {
            if Task.isCancelled { return }
            guard let translator = TranslatorFactory.make(
                engine: engine, settings: s, aiKey: aiKey()) else { continue }
            engineLabel = translator.label
            do {
                let result = try await translator.translate(text, from: nil, to: target)
                guard !Task.isCancelled else { return }
                apply(result)
                return
            } catch {
                lastError = error
            }
        }
        if !Task.isCancelled { fail(lastError) }
    }

    private func startApple(text: String, source: String, target: String) {
        guard #available(macOS 15.0, *) else {
            fail(TranslationError.appleUnavailable)
            return
        }
        #if canImport(Translation)
        engineLabel = "Apple 本地"
        applePendingText = text
        appleConfiguration = AppleTranslationConfiguration.make(source: source, target: target)
        appleRequestID += 1
        isWorking = true
        #else
        fail(TranslationError.appleUnavailable)
        #endif
    }

    // MARK: 视图回调

    public func applyApple(_ text: String, sourceLanguage: String?) {
        guard !text.isEmpty else {
            fail(TranslationError.malformed)
            return
        }
        apply(TranslationOutput(text: text, detectedLanguage: sourceLanguage, engine: .apple))
    }

    public func failApple(_ message: String) {
        // Translation.framework 的语言包错误文案是英文，换成人话
        if message.localizedCaseInsensitiveContains("language pair")
            || message.localizedCaseInsensitiveContains("not supported") {
            fail(TranslationError.unsupportedPair)
        } else {
            fail(TranslationError.message("Apple 翻译失败：\(message)"))
        }
    }

    private func apply(_ result: TranslationOutput) {
        output = result.text
        detectedLanguage = result.detectedLanguage
        engineLabel = result.engine == .apple ? "Apple 本地" : engineLabel
        isWorking = false
        errorMessage = nil
    }

    private func fail(_ error: Error) {
        errorMessage = (error as? TranslationError)?.errorDescription
            ?? error.localizedDescription
        isWorking = false
    }

    // MARK: 动作

    public func copyResult() {
        guard let output, !output.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(output, forType: .string)
        copied = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.copied = false
        }
    }

    public func speak() {
        guard let output, !output.isEmpty else { return }
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: output)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.speechLanguage(for: targetLanguage))
        speech.speak(utterance)
    }

    public func stopSpeaking() {
        speech.stopSpeaking(at: .immediate)
    }

    static func speechLanguage(for code: String) -> String {
        switch code {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        default: return code
        }
    }

    public var detectedLabel: String {
        guard let detectedLanguage else { return "" }
        return Locale.current.localizedString(forLanguageCode: detectedLanguage)
            ?? detectedLanguage
    }
}
