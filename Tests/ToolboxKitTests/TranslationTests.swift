import AppKit
import Foundation
import Testing
@testable import ToolboxKit

private final class FakeTransport: HTTPFetching, HTTPPosting, @unchecked Sendable {
    var getHandler: ((URL) throws -> Data)?
    var postHandler: ((URL, Data) throws -> Data)?
    private(set) var lastGetURL: URL?
    private(set) var lastPostURL: URL?
    private(set) var lastBody = Data()
    private(set) var lastHeaders: [String: String] = [:]

    func get(_ url: URL) async throws -> Data {
        lastGetURL = url
        return try getHandler?(url) ?? Data()
    }

    func download(_ url: URL, to file: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {}

    func post(_ url: URL, contentType: String, body: Data,
              headers: [String: String]) async throws -> Data {
        lastPostURL = url
        lastBody = body
        lastHeaders = headers
        return try postHandler?(url, body) ?? Data()
    }
}

@MainActor
private final class FakeAX: AXSelectionProviding {
    var text: String?
    var element: AXUIElement?
    var replaceSucceeds = false
    private(set) var replaced: String?

    func selectedText() -> (text: String, element: AXUIElement?)? {
        guard let text else { return nil }
        return (text, element)
    }

    func replaceSelection(in element: AXUIElement, with text: String) -> Bool {
        replaced = text
        return replaceSucceeds
    }
}

@MainActor
private final class FakeKeys: CommandKeySending {
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var copyResult = true
    var pasteResult = true

    func sendCopy() -> Bool { onCopy?(); return copyResult }
    func sendPaste() -> Bool { onPaste?(); return pasteResult }
}

// MARK: 设置解码

@Test func translationSettingsDecodesMissingFieldsAndUnknownEngine() throws {
    let json = Data(#"{"engine":"some-future-engine","targetLanguage":"ja"}"#.utf8)
    let s = try JSONDecoder().decode(TranslationSettings.self, from: json)
    #expect(s.engine == .auto)
    #expect(s.targetLanguage == "ja")
    #expect(s.proxyPort == 10809)
    #expect(s.network == .auto)
}

@Test func appSettingsWithoutTranslationSectionStillDecodes() throws {
    let json = Data(#"{"clipboardCapacity":12}"#.utf8)
    let s = try JSONDecoder().decode(AppSettings.self, from: json)
    #expect(s.translation == TranslationSettings())
}

// MARK: 语言与网络策略

@Test func languageCodesMatchEachEngine() {
    #expect(TranslationLanguages.youdaoCode(for: "zh-Hans") == "zh-CHS")
    #expect(TranslationLanguages.youdaoCode(for: "ja") == "ja")
    #expect(TranslationLanguages.webCode(for: "zh-Hans") == "zh-CN")
    #expect(TranslationLanguages.webCode(for: "zh-Hant") == "zh-TW")
    #expect(TranslationLanguages.guessSource("こんにちは") == "ja")
    #expect(TranslationLanguages.guessSource("안녕하세요") == "ko")
    #expect(TranslationLanguages.guessSource("你好") == "zh-Hans")
    #expect(TranslationLanguages.guessSource("hello") == "en")
    #expect(TranslationLanguages.effectiveTarget(source: "zh-Hans", target: "zh-Hant")
        == "zh-Hant")
    #expect(TranslationLanguages.effectiveTarget(source: "en", target: "en") == "zh-Hans")
}

@Test func autoNetworkKeepsDomesticHostsDirect() {
    var s = TranslationSettings(network: .auto, proxyPort: 10809)
    #expect(TranslationNetworkPolicy.proxyPort(for: "aidemo.youdao.com", settings: s) == nil)
    #expect(TranslationNetworkPolicy.proxyPort(for: "api.mymemory.translated.net", settings: s) == nil)
    #expect(TranslationNetworkPolicy.proxyPort(for: "translate.googleapis.com", settings: s) == 10809)
    #expect(TranslationNetworkPolicy.proxyPort(for: "api.openai.com", settings: s) == 10809)

    s.network = .direct
    #expect(TranslationNetworkPolicy.proxyPort(for: "translate.googleapis.com", settings: s) == nil)
    s.network = .proxy
    #expect(TranslationNetworkPolicy.proxyPort(for: "aidemo.youdao.com", settings: s) == 10809)
}

// MARK: 引擎解析

@Test func youdaoParsesTranslationAndDetectedLanguage() async throws {
    let t = FakeTransport()
    let json = #"{"errorCode":0,"translation":["你好","世界"],"l":"en2zh-CHS"}"#
    t.postHandler = { _, _ in Data(json.utf8) }
    let out = try await YoudaoTranslator(fetcher: t)
        .translate("Hello world", from: nil, to: "zh-Hans")
    #expect(out.text == "你好世界")
    #expect(out.detectedLanguage == "en")
    #expect(t.lastPostURL?.absoluteString == "https://aidemo.youdao.com/trans")
    let body = String(decoding: t.lastBody, as: UTF8.self)
    #expect(body.contains("from=auto"))
    #expect(body.contains("to=zh-CHS"))
    #expect(body.contains("q=Hello%20world") || body.contains("q=Hello+world"))
}

@Test func youdaoRejectsNonZeroErrorCode() async {
    let t = FakeTransport()
    t.postHandler = { _, _ in Data(#"{"errorCode":411,"translation":[]}"#.utf8) }
    await #expect(throws: TranslationError.self) {
        try await YoudaoTranslator(fetcher: t).translate("hi", from: nil, to: "zh-Hans")
    }
}

@Test func myMemoryUsesGuessedSourceAndDecodesEntities() async throws {
    let t = FakeTransport()
    let json = #"{"responseStatus":200,"responseData":{"translatedText":"Tom &amp; Jerry"}}"#
    t.getHandler = { _ in Data(json.utf8) }
    let out = try await MyMemoryTranslator(fetcher: t)
        .translate("Tom and Jerry", from: nil, to: "zh-Hans")
    #expect(out.text == "Tom & Jerry")
    #expect(out.detectedLanguage == "en")
    #expect(t.lastGetURL?.query?.contains("langpair=en%7Czh-CN") == true)
}

@Test func googleParsesSegmentArrayAndRejectsHTML() async throws {
    let t = FakeTransport()
    t.getHandler = { _ in
        Data(#"[[["你好","Hello",null,null,10]],null,"en"]"#.utf8)
    }
    let out = try await GoogleTranslator(fetcher: t).translate("Hello", from: nil, to: "zh-Hans")
    #expect(out.text == "你好")
    #expect(out.detectedLanguage == "en")

    t.getHandler = { _ in Data("<html>Sorry…</html>".utf8) }
    await #expect(throws: TranslationError.self) {
        try await GoogleTranslator(fetcher: t).translate("Hello", from: nil, to: "zh-Hans")
    }
}

@Test func aiPostsOpenAICompatibleBodyAndNeedsKey() async throws {
    let t = FakeTransport()
    t.postHandler = { _, _ in
        Data(#"{"choices":[{"message":{"content":" 你好 "}}]}"#.utf8)
    }
    let translator = AITranslator(
        fetcher: t, baseURL: "https://api.deepseek.com/v1",
        model: "deepseek-chat", apiKey: "sk-test")
    let out = try await translator.translate("Hello", from: nil, to: "zh-Hans")
    #expect(out.text == "你好")
    #expect(t.lastPostURL?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
    #expect(t.lastHeaders["Authorization"] == "Bearer sk-test")
    let body = try JSONSerialization.jsonObject(with: t.lastBody) as? [String: Any]
    #expect(body?["model"] as? String == "deepseek-chat")

    let noKey = AITranslator(fetcher: t, baseURL: "https://x/v1", model: "m", apiKey: nil)
    await #expect(throws: TranslationError.self) {
        try await noKey.translate("Hello", from: nil, to: "zh-Hans")
    }
}

// MARK: 浮窗尺寸

@Test @MainActor func panelHeightFollowsTextAndClamps() {
    let short = TranslationPanelController.panelHeight(
        source: "Hi", output: "你好", error: nil, working: false)
    let longText = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 20)
    let long = TranslationPanelController.panelHeight(
        source: longText, output: longText, error: nil, working: false)
    #expect(short >= TranslationPanelController.minHeight)
    #expect(short < long)
    #expect(long == TranslationPanelController.maxHeight)
}

// MARK: 取词

@Test @MainActor func axSelectionWinsWithoutTouchingClipboard() async {
    let pb = NSPasteboard(name: NSPasteboard.Name("translate-ax-\(UUID())"))
    pb.clearContents()
    pb.setString("原有", forType: .string)

    let ax = FakeAX()
    ax.text = "选中的英文"
    ax.element = AXUIElementCreateSystemWide()
    let keys = FakeKeys()
    keys.onCopy = { Issue.record("AX 命中时不该再发 ⌘C") }

    let reader = SelectionReader(ax: ax, keys: keys, tracker: SelfWriteTracker(),
                                 pasteboard: pb, copyTimeout: 0.2)
    let capture = await reader.read()
    #expect(capture?.text == "选中的英文")
    #expect(capture?.source == .accessibility)
    #expect(pb.string(forType: .string) == "原有")
}

@Test @MainActor func copyFallbackRestoresClipboardAndMarksSelfWrite() async {
    let pb = NSPasteboard(name: NSPasteboard.Name("translate-copy-\(UUID())"))
    pb.clearContents()
    pb.setString("用户原来的剪贴板", forType: .string)

    let ax = FakeAX()
    let keys = FakeKeys()
    keys.onCopy = {
        pb.clearContents()
        pb.setString("Hello world", forType: .string)
    }
    let tracker = SelfWriteTracker()
    let reader = SelectionReader(ax: ax, keys: keys, tracker: tracker,
                                 pasteboard: pb, copyTimeout: 0.3)

    let capture = await reader.read()
    #expect(capture?.text == "Hello world")
    #expect(capture?.source == .copy)
    #expect(pb.string(forType: .string) == "用户原来的剪贴板")
    #expect(tracker.isWithinGrace(now: Date()))
}

@Test @MainActor func copyTimeoutLeavesClipboardIntact() async {
    let pb = NSPasteboard(name: NSPasteboard.Name("translate-timeout-\(UUID())"))
    pb.clearContents()
    pb.setString("原样", forType: .string)

    let keys = FakeKeys()   // 不发任何键，模拟目标 App 不支持 ⌘C
    let reader = SelectionReader(ax: FakeAX(), keys: keys, tracker: SelfWriteTracker(),
                                 pasteboard: pb, copyTimeout: 0.15)
    let capture = await reader.read()
    #expect(capture == nil)
    #expect(pb.string(forType: .string) == "原样")
}

@Test @MainActor func replacePrefersAXThenFallsBackToPaste() async {
    let pb = NSPasteboard(name: NSPasteboard.Name("translate-replace-\(UUID())"))
    let ax = FakeAX()
    let element = AXUIElementCreateSystemWide()
    ax.element = element
    ax.replaceSucceeds = true
    let keys = FakeKeys()
    let reader = SelectionReader(ax: ax, keys: keys, tracker: SelfWriteTracker(),
                                 pasteboard: pb, copyTimeout: 0.2)

    let viaAX = SelectionCapture(text: "x", element: element, source: .accessibility)
    #expect(reader.replace(viaAX, with: "译文"))
    #expect(ax.replaced == "译文")

    ax.replaceSucceeds = false
    var pasted = false
    keys.onPaste = { pasted = true }
    #expect(reader.replace(viaAX, with: "回退译文"))
    #expect(pasted)
    #expect(pb.string(forType: .string) == "回退译文")
}
