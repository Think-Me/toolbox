import AppKit
import Carbon.HIToolbox

/// 剪贴板历史面板：呼出、加载、键盘导航、粘贴。
///
/// 键盘分工是刻意的，两件事各走各的正规通道：
/// - ⌘1…⌘9 / ⌘P / ⌘⌫ → `ClipboardRootView.performKeyEquivalent`
///   （NSWindow 在把键交给字段编辑器之前会先问一遍 contentView 层级，
///    所以搜索框正在输入时也能收到）
/// - ↑↓ / Esc / ⌫ → responder chain 的 action 方法（本类的 @objc 方法）
///   单行文本框不处理 moveUp:/moveDown:，它们会自然冒泡到这里。
/// - 粘贴入口只有两个：**单击行** 或 **⌘数字**。回车故意不粘贴（用户要求）。
@MainActor
public final class ClipboardPanelController: NSResponder {
    private let store: ClipboardStore
    private let media: MediaStore
    private let simulator: PasteSimulator
    private let presenter: PanelPresenter
    private let settingsProvider: () -> AppSettings

    private var items: [ClipboardItem] = []
    private var selection = ClipboardListSelection(count: 0)
    private var listView: ClipboardListView?
    private var query = ""
    private var degradeNote: String?

    public static var panelWidth: CGFloat { ClipboardStyle.panelWidth }
    public static let panelHeight: CGFloat = 420

    public init(store: ClipboardStore, media: MediaStore, simulator: PasteSimulator,
                presenter: PanelPresenter = .shared,
                settings: @escaping () -> AppSettings) {
        self.store = store
        self.media = media
        self.simulator = simulator
        self.presenter = presenter
        self.settingsProvider = settings
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("不支持从 nib 构造") }

    // MARK: 呼出

    public func show() {
        Task { @MainActor in await reload() }
        let view = ClipboardListView()
        view.media = media
        view.onQueryChanged = { [weak self] q in
            guard let self else { return }
            self.query = q
            Task { @MainActor in await self.reload() }
        }
        view.root.onQuickPick = { [weak self] keyCode in self?.quickPick(keyCode) ?? false }
        view.onRowClicked = { [weak self] row in self?.clickRow(row) }
        view.root.onPinToggled = { [weak self] in self?.togglePin() ?? false }
        view.root.onDeleteRequested = { [weak self] in self?.deleteCurrent() ?? false }
        listView = view

        presenter.show(content: view.root, anchor: .cursor,
                       width: Self.panelWidth, height: Self.panelHeight) { [weak self] _ in
            self?.listView = nil
            self?.query = ""
            self?.degradeNote = nil
        }
        // 把本对象插进 responder chain：视图链走完才轮到窗口，
        // 中间插一层就能拿到 moveUp:/insertNewline: 这些 action
        view.root.nextResponder = self
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presenter.windowForFocus?.makeFirstResponder(view.searchField)
        }
    }

    private func reload() async {
        let limit = max(1, settingsProvider().clipboardCapacity)
        let fetched: [ClipboardItem]
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            fetched = (try? await store.recent(limit: limit)) ?? []
        } else {
            fetched = (try? await store.search(query, limit: limit)) ?? []
        }
        items = fetched
        if query.isEmpty {
            selection.setCount(fetched.count)
        } else {
            selection.applyFilter(count: fetched.count)
        }
        listView?.items = items
        if selection.isValid { listView?.highlight(row: selection.index) }
    }

    // MARK: responder chain 动作

    @objc public override func moveUp(_ sender: Any?) {
        selection.move(-1)
        listView?.highlight(row: selection.index)
    }

    @objc public override func moveDown(_ sender: Any?) {
        selection.move(1)
        listView?.highlight(row: selection.index)
    }

    /// 回车**故意不粘贴**（用户要求：粘贴只靠点击行或 ⌘数字）。
    /// 显式吞掉而不是删掉这个方法：留着它，回车就不会冒泡到默认按钮触发意外动作。
    @objc public override func insertNewline(_ sender: Any?) {}

    private func clickRow(_ row: Int) {
        guard items.indices.contains(row) else { return }
        selection.select(row)
        listView?.highlight(row: row)
        let item = items[row]
        Task { @MainActor in await commit(item) }
    }

    @objc public override func cancelOperation(_ sender: Any?) {
        presenter.dismissCurrent(reason: .escape)
    }

    @objc public override func deleteBackward(_ sender: Any?) {
        // 搜索框里有字时 ⌫ 该删字，不能越俎代庖删掉整条历史
        guard (listView?.searchField.stringValue ?? "").isEmpty else { return }
        _ = deleteCurrent()
    }

    // MARK: 动作

    private func quickPick(_ keyCode: UInt16) -> Bool {
        guard let row = selection.quickPick(keyCode: keyCode), row < items.count else { return false }
        selection.select(row)
        listView?.highlight(row: row)
        let item = items[row]
        Task { @MainActor in await commit(item) }
        return true
    }

    private func togglePin() -> Bool {
        guard let item = selection.current(in: items) else { return false }
        Task { @MainActor in
            try? await store.setPinned(id: item.id, !item.pinned)
            await reload()
        }
        return true
    }

    private func deleteCurrent() -> Bool {
        guard let item = selection.current(in: items) else { return false }
        Task { @MainActor in
            let shas = (try? await store.delete(id: item.id)) ?? []
            if !shas.isEmpty {
                _ = try? await store.trim(to: settingsProvider().clipboardCapacity)
                _ = try? media.garbageCollect(liveSHAs: Set((try? await store.allMediaSHAs()) ?? []))
            }
            await reload()
        }
        return true
    }

    /// 粘贴。面板一律在发键之前关掉（见 prepare）；降级/失败时用非模态提示条说明原因，
    /// 不用 NSAlert —— 那时焦点刚还给目标 App，弹模态框会打断用户输入。
    private func commit(_ item: ClipboardItem) async {
        let target = presenter.frontAppBeforePresentation
        // prepare 里关面板：**必须在发 ⌘V 之前**。面板还开着时它是 key window，
        // 合成的 ⌘V 会被投给我们自己的面板而不是目标 App（实测：内容复制了但没粘上）。
        let outcome = await simulator.paste(item, into: target) { [weak self] in
            self?.presenter.dismissCurrent(reason: .chose)
        }
        switch outcome {
        case .pasted:
            try? await store.bump(id: item.id, at: Date())
        case .copiedOnly(let degrade):
            try? await store.bump(id: item.id, at: Date())
            degradeNote = Self.explain(degrade)
            showNote(degradeNote)
        case .failed(let failure):
            degradeNote = Self.explain(failure)
            showNote(degradeNote)
        }
    }

    /// 降级/失败要让人看见。面板此时已经关了，所以用非模态的浮动提示，
    /// 不抢焦点、几秒后自己消失。
    private func showNote(_ text: String?) {
        guard let text else { return }
        DegradeNotice.shared.show(text)
    }

    static func explain(_ degrade: PasteOutcome.Degrade) -> String {
        switch degrade {
        case .accessibilityNotGranted:
            return "已复制，未自动粘贴：需要辅助功能权限（设置 → 权限与授权）"
        case .targetAppUnknown:
            return "已复制，未自动粘贴：找不到原来的 App，请手动 ⌘V"
        case .secureInputActive:
            return "已复制，未自动粘贴：当前输入框开启了安全输入（密码框/终端 sudo）"
        case .timedOut:
            return "已复制，未自动粘贴：切换前台超时，请手动 ⌘V"
        }
    }

    static func explain(_ failure: PasteFailure) -> String {
        switch failure {
        case .emptyItem:            return "这条记录是空的，已跳过"
        case .pasteboardLocked:     return "剪贴板被其它 App 锁定，稍后再试"
        case .imageMissing(let s):  return "图片文件已丢失（sha \(s.prefix(8))…），历史记录仍在"
        case .keystrokePostFailed:  return "已复制，但按键发送失败，请手动 ⌘V"
        }
    }
}
