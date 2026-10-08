import AppKit
import Carbon.HIToolbox

/// 面板根视图。承担两件事：
/// 1. `performKeyEquivalent` 抢在字段编辑器之前吃掉 ⌘1…⌘9 / ⌘P / ⌘⌫
///    （NSWindow 会先在 contentView 层级上问一遍，所以搜索框正在输入时也能收到）
/// 2. 上下键/回车/Esc 不在这里处理 —— 那些走 responder chain 的 action 方法，
///    见 ClipboardPanelController 的 moveUp(_:) / insertNewline(_:) 等
@MainActor
public final class ClipboardRootView: NSView {
    public var onQuickPick: ((UInt16) -> Bool)?
    public var onPinToggled: (() -> Bool)?
    public var onDeleteRequested: (() -> Bool)?

    public override var isFlipped: Bool { true }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }

        if flags.contains(.option) || flags.contains(.control) { return false }
        switch event.keyCode {
        case UInt16(kVK_ANSI_P):
            return onPinToggled?() ?? false
        case UInt16(kVK_Delete):
            return onDeleteRequested?() ?? false
        default:
            return onQuickPick?(event.keyCode) ?? false
        }
    }
}

/// 搜索框。文本变化走 NSTextFieldDelegate（`controlTextDidChange` 不是 NSControl
/// 上可覆写的方法，之前写成 override 编译不过），键盘导航交给 responder chain。
@MainActor
public final class ClipboardSearchField: NSSearchField {}

/// 列表行高与列布局。
enum ClipboardRowLayout {
    static let height: CGFloat = 52
    static let thumbnail: CGFloat = 36
    static let horizontalInset: CGFloat = 10
}

@MainActor
public final class ClipboardListView: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                                    NSTextFieldDelegate, NSSearchFieldDelegate {
    public private(set) var tableView: NSTableView!
    public private(set) var searchField: ClipboardSearchField!
    public private(set) var root: ClipboardRootView!

    public var items: [ClipboardItem] = [] {
        didSet { tableView?.reloadData() }
    }
    public var onQueryChanged: ((String) -> Void)?
    public let thumbnails = ThumbnailCache()
    /// 由控制器注入。cell 不该去够一个全局单例，那样测试和依赖方向都失控。
    public var media: MediaStore?

    public override init() {
        super.init()
        let root = ClipboardRootView(frame: NSRect(x: 0, y: 0, width: 460, height: 360))
        self.root = root
        // 面板整体按深色外观渲染：否则 NSSearchField 会画成白底，
        // 在深色面板上像贴了一张纸
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.98).cgColor
        root.layer?.borderColor = NSColor(calibratedWhite: 0.45, alpha: 1).cgColor
        root.layer?.borderWidth = 1
        root.layer?.cornerRadius = 10

        let search = ClipboardSearchField(frame: NSRect(x: 10, y: 328, width: 440, height: 24))
        search.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "搜索剪贴板历史"
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 13)
        search.delegate = self
        self.searchField = search

        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        // 系统高亮在深色 borderless 面板上不可控（.regular 会画浅灰底，白字压上去看不清；
        // AppKit 又没有 .emphasized），所以关掉系统高亮，自己画行背景。
        table.selectionHighlightStyle = .none
        table.rowHeight = ClipboardRowLayout.height
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.width = 440
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        self.tableView = table

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table

        root.addSubview(search)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            search.heightAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
    }

    public func controlTextDidChange(_ obj: Notification) {
        onQueryChanged?(searchField?.stringValue ?? "")
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        ClipboardRowLayout.height
    }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]
        let cell = ClipboardCellView.dequeue(from: tableView)
        cell.configure(with: item, media: media, thumbnails: thumbnails)
        return cell
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ClipboardRowView()
    }

    /// 选中态由我们自己画（面板不是标准窗口，系统高亮在 borderless 上不稳）
    public func highlight(row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }
}

/// 缩略图缓存：读盘 + 降采样放后台，面板首帧不被它拖住。
///
/// 回调一律留在 MainActor 侧的字典里，跨任务边界只传 sha（值类型）。
/// 直接把 `@MainActor` 闭包带进 `Task.detached` 会被 Swift 6 的 sending 检查拦下，
/// 那不是在为难你 —— 那个闭包确实会在并发上下文里被持有。
@MainActor
public final class ThumbnailCache {
    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: Set<String> = []
    private var waiters: [String: [@MainActor (NSImage) -> Void]] = [:]

    public init() { cache.countLimit = 300 }

    /// 命中返回图片；未命中返回 nil 并在算好后回调（同一 sha 并发请求会合并）。
    public func image(forSHA sha: String, from media: MediaStore, maxPixel: CGFloat = 72,
                      onReady: @escaping @MainActor (NSImage) -> Void) -> NSImage? {
        if let hit = cache.object(forKey: sha as NSString) { return hit }
        waiters[sha, default: []].append(onReady)
        guard !inFlight.contains(sha) else { return nil }
        inFlight.insert(sha)
        // 从 MainActor 侧起任务、await 后台算完的值，self 全程不跨并发边界
        // （直接 `Task.detached { [weak self] ... }` 会被判成 sending self）
        Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) {
                Self.loadDownsampled(sha: sha, media: media, maxPixel: maxPixel)
            }.value
            finish(sha: sha, image: loaded)
        }
        return nil
    }

    private func finish(sha: String, image: NSImage?) {
        inFlight.remove(sha)
        let callbacks = waiters.removeValue(forKey: sha) ?? []
        if let image {
            cache.setObject(image, forKey: sha as NSString)
            for cb in callbacks { cb(image) }
        }
    }

    nonisolated private static func loadDownsampled(sha: String, media: MediaStore,
                                                    maxPixel: CGFloat) -> NSImage? {
        guard let data = try? media.data(sha: sha),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        return NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))
    }
}

/// 单行：类型图标 / 缩略图 + 摘要 + 来源 + 相对时间 + 置顶标记。
@MainActor
public final class ClipboardCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("clipboard.cell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private var boundSHA: String?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 12)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 2
        meta.translatesAutoresizingMaskIntoConstraints = false
        meta.font = .systemFont(ofSize: 10)
        meta.textColor = NSColor(calibratedWhite: 0.65, alpha: 1)
        meta.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(title)
        addSubview(meta)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor,
                                          constant: ClipboardRowLayout.horizontalInset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: ClipboardRowLayout.thumbnail),
            icon.heightAnchor.constraint(equalToConstant: ClipboardRowLayout.thumbnail),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            meta.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            meta.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            meta.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持从 nib 构造") }

    func configure(with item: ClipboardItem, media: MediaStore?,
                   thumbnails: ThumbnailCache) {
        title.stringValue = item.displayPreview
        let source = item.sourceAppName ?? item.sourceBundleID ?? "未知来源"
        let pin = item.pinned ? "置顶 · " : ""
        meta.stringValue = "\(pin)\(source) · \(RelativeTime.short(item.lastCopiedAt)) · \(item.kindLabel)"
        boundSHA = item.mediaSHA256

        if item.kind == .image, let sha = item.mediaSHA256, let media {
            icon.image = placeholderIcon(for: item)
            _ = thumbnails.image(forSHA: sha, from: media) { [weak self] img in
                // 复用池里的 cell 可能已经被派给别的行，回来时必须再核对一次
                guard let self, self.boundSHA == sha else { return }
                self.icon.image = img
            }
        } else {
            icon.image = placeholderIcon(for: item)
            icon.contentTintColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        }
    }

    private func placeholderIcon(for item: ClipboardItem) -> NSImage? {
        NSImage(systemSymbolName: item.kindSymbol, accessibilityDescription: item.kindLabel)
    }
}

extension ClipboardCellView {
    /// 从复用池取 cell；取不到就新建并挂上标识，下一行起就能复用了。
    static func dequeue(from table: NSTableView) -> ClipboardCellView {
        if let reused = table.makeView(withIdentifier: reuseID, owner: nil) as? ClipboardCellView {
            return reused
        }
        let cell = ClipboardCellView(frame: .zero)
        cell.identifier = reuseID
        return cell
    }
}


extension ClipboardItem {
    var kindLabel: String {
        switch kind {
        case .text: return "文本"
        case .image: return "图片"
        case .fileURLs: return "文件"
        }
    }
    var kindSymbol: String {
        switch kind {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .fileURLs: return "doc.on.doc"
        }
    }
}

/// 相对时间。列表里显示绝对时间太宽也看不出远近。
enum RelativeTime {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case 0..<60: return "刚刚"
        case 60..<3_600: return "\(s / 60) 分钟前"
        case 3_600..<86_400: return "\(s / 3_600) 小时前"
        case 86_400..<2_592_000: return "\(s / 86_400) 天前"
        default: return "更早"
        }
    }
}

/// 自己画选中背景的行视图。
@MainActor
final class ClipboardRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        guard isSelected else { return }
        // 半透明蓝：深色/浅色背景下都能和白字保持对比度
        NSColor(calibratedRed: 0.24, green: 0.42, blue: 0.86, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 3), xRadius: 6, yRadius: 6).fill()
    }
}
