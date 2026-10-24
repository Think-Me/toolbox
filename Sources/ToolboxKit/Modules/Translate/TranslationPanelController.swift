import AppKit
import Combine
import SwiftUI

/// 划词翻译的总装：取词 → 起模型 → 弹浮窗 → 替换原文。
///
/// 取词是异步的（AX 同步、⌘C 回退要等 pasteboard），所以 `present()` 自己开 Task；
/// 热键回调是同步接口，不能在这里阻塞主线程 0.6s。
@MainActor
public final class TranslationPanelController {
    /// 窄一点更不挡阅读；宽度固定，高度随文本量变化。
    public static let panelWidth: CGFloat = 340
    static let minHeight: CGFloat = 150
    static let maxHeight: CGFloat = 440

    private let reader: SelectionReader
    private let model: TranslationModel
    private var capture: SelectionCapture?
    private var presenting = false
    private var panelHost: NSView?
    private var resizeObserver: AnyCancellable?

    public init(settings: @escaping () -> TranslationSettings,
                reader: SelectionReader,
                aiKey: @escaping () -> String? = { KeychainStore.aiKey },
                engineDidChange: ((TranslationEngine) -> Void)? = nil) {
        self.reader = reader
        self.model = TranslationModel(settings: settings, aiKey: aiKey,
                                      engineDidChange: engineDidChange)
    }

    /// 测试与设置页可能要看状态
    public var translationModel: TranslationModel { model }

    public func present() {
        Task { @MainActor in await presentNow() }
    }

    /// 不经过取词，直接用给定文本弹窗（`--translate-panel-preview` 用）。
    public func present(text: String) {
        capture = nil
        model.begin(text: text)
        showPanel()
    }

    private func presentNow() async {
        guard !presenting else { return }
        presenting = true
        defer { presenting = false }
        guard let captured = await reader.read() else {
            DegradeNotice.shared.show("没有选中文本，或当前 App 不支持取词")
            return
        }
        capture = captured
        model.begin(text: captured.text)
        showPanel()
    }

    private func showPanel() {
        // 超长文本会被模型截断；此时"替换原文"会把整段选区换成半截译文，宁可不给点
        let replaceable = capture.map { $0.text.count <= TranslationModel.maxCharacters } ?? false
        let view = TranslationPanelView(
            model: model,
            canReplace: replaceable,
            onReplace: { [weak self] in self?.replaceSelection() })
        let size = currentSize()
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        panelHost = host
        observeResize()
        PanelPresenter.shared.show(
            content: host, anchor: .cursor,
            width: size.width, height: size.height
        ) { [weak self] _ in
            self?.model.stopSpeaking()
            self?.resizeObserver = nil
            self?.panelHost = nil
        }
    }

    /// 译文到达、重译、报错都会改变高度；跟着内容重设窗口尺寸。
    private func observeResize() {
        resizeObserver = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                DispatchQueue.main.async { self?.resizeIfNeeded() }
            }
    }

    private func resizeIfNeeded() {
        guard let host = panelHost,
              PanelPresenter.shared.windowForFocus?.contentView === host else { return }
        let size = currentSize()
        guard abs(host.frame.width - size.width) > 0.5
                || abs(host.frame.height - size.height) > 0.5 else { return }
        PanelPresenter.shared.resize(width: size.width, height: size.height)
    }

    private func currentSize() -> CGSize {
        CGSize(width: Self.panelWidth,
               height: Self.panelHeight(source: model.sourceText,
                                        output: model.output,
                                        error: model.errorMessage,
                                        working: model.isWorking))
    }

    /// 高度由"固定 chrome + 原文（最多 5 行）+ 译文（最多 16 行）"算出。
    /// 超出上限就固定高度、交给浮窗内的滚动视图。
    static func panelHeight(source: String, output: String?, error: String?,
                            working: Bool) -> CGFloat {
        let textWidth = panelWidth - 28 - 2
        let sourceHeight = min(measure(source, font: .systemFont(ofSize: 12), width: textWidth),
                               5 * 17)
        let body: String
        let bodyFont: NSFont
        if let error {
            body = error
            bodyFont = .systemFont(ofSize: 12)
        } else if let output {
            body = output
            bodyFont = .systemFont(ofSize: 13)
        } else {
            body = working ? "翻译中…" : "…"
            bodyFont = .systemFont(ofSize: 12)
        }
        let bodyHeight = min(max(measure(body, font: bodyFont, width: textWidth), 18), 16 * 17)
        let chrome: CGFloat = 168
        return min(max(chrome + sourceHeight + bodyHeight, minHeight), maxHeight)
    }

    private static func measure(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return ceil(rect.height)
    }

    private func replaceSelection() {
        guard let capture, let text = model.output else { return }
        if reader.replace(capture, with: text) {
            PanelPresenter.shared.dismissCurrent(reason: .chose)
        } else {
            DegradeNotice.shared.show("替换失败：目标 App 不允许写回，可手动复制译文")
        }
    }
}
