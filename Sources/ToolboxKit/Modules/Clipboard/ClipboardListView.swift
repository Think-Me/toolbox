import AppKit
import Carbon.HIToolbox

/// 面板根视图。承担 ⌘1…⌘9 / ⌘P / ⌘ 的快捷键捕获。
///
/// 分工是刻意的：
/// - 带 ⌘ 的组合键 → `performKeyEquivalent`（NSWindow 在把键交给字段编辑器之前
///   会先问一遍 contentView 层级，所以搜索框正在输入时也能收到）
/// - ↑↓ / Esc → responder chain 的 action 方法，见 ClipboardPanelController
/// - 回车**故意不粘贴**（用户要求：粘贴只靠点击行或 ⌘数字）
@MainActor
public final class ClipboardRootView: NSView {
    public var onQuickPick: ((UInt16) -> Bool)?
    public var onPinToggled: (() -> Bool)?
    public var onDeleteRequested: (() -> Bool)?
    /// ⌘E：把选中的图片条目钉到屏幕（剪贴板 → 贴图，唯一的跨模块出口）
    public var onPinToScreenRequested: (() -> Bool)?

    public override var isFlipped: Bool { true }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control)
        else { return false }

        switch event.keyCode {
        case UInt16(kVK_ANSI_P):
            return onPinToggled?() ?? false
        case UInt16(kVK_ANSI_E):
            return onPinToScreenRequested?() ?? false
        case UInt16(kVK_Delete):
            return onDeleteRequested?() ?? false
        default:
            return onQuickPick?(event.keyCode) ?? false
        }
    }
}

/// 尺寸与配色常量。集中一处，改视觉不用翻文件。
enum ClipboardStyle {
    static let panelWidth: CGFloat = 360
    /// 头部（标题 + 搜索框 + 与列表的间距）实际占的高度。
    /// 面板总高按它算，所以这个值必须和 updateNSView 里的布局一致。
    static let headerHeight: CGFloat = 46
    static let rowHeightText: CGFloat = 30
    static let rowHeightImage: CGFloat = 72
    static let thumbnail: CGFloat = 56
    static let inset: CGFloat = 12
    static let verticalPadding: CGFloat = 12
    static let title = "历史纪录"

    /// 快贴那种浅灰磨砂底 + 近黑正文 + 中灰次要文字。
    /// 用系统语义色而不是写死 RGB，这样浅色/深色/增强对比度都能跟着走。
    static var primaryText: NSColor { .labelColor }
    static var secondaryText: NSColor { .secondaryLabelColor }
    static var chevron: NSColor { .tertiaryLabelColor }
    static var selection: NSColor { NSColor.selectedContentBackgroundColor.withAlphaComponent(0.16) }
    static var hover: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.10) }
}

@MainActor
public final class ClipboardListView: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                                    NSTextFieldDelegate, NSSearchFieldDelegate {
    public private(set) var tableView: NSTableView!
    public private(set) var searchField: NSSearchField!
    public private(set) var root: ClipboardRootView!

    public var items: [ClipboardItem] = [] {
        didSet { tableView?.reloadData() }
    }
    public var onQueryChanged: ((String) -> Void)?
    /// 单击一行 = 粘贴该条。
    public var onRowClicked: ((Int) -> Void)?
    public let thumbnails = ThumbnailCache()
    public var media: MediaStore?

    public override init() {
        super.init()
        let root = ClipboardRootView(frame: NSRect(x: 0, y: 0,
                                                   width: ClipboardStyle.panelWidth,
                                                   height: 420))
        self.root = root
        root.appearance = NSAppearance(named: .aqua)   // 磨砂浅底 + 深字，对齐快贴
        root.wantsLayer = true
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true

        let effect = NSVisualEffectView()
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        root.addSubview(effect, positioned: .below, relativeTo: nil)

        let title = NSTextField(labelWithString: ClipboardStyle.title)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let search = NSSearchField()
        search.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "搜索"
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 12)
        search.delegate = self
        self.searchField = search

        let table = HoveringTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none          // 自画选中背景
        table.rowHeight = ClipboardStyle.rowHeightText
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.width = ClipboardStyle.panelWidth
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        self.tableView = table

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.documentView = table

        root.addSubview(title)
        root.addSubview(search)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: root.topAnchor),
            effect.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            effect.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                           constant: ClipboardStyle.inset),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                             constant: -ClipboardStyle.inset),
            search.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            search.widthAnchor.constraint(equalToConstant: 132),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        onRowClicked?(row)
    }

    public func controlTextDidChange(_ obj: Notification) {
        onQueryChanged?(searchField?.stringValue ?? "")
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        items.indices.contains(row) && items[row].kind == .image
            ? ClipboardStyle.rowHeightImage : ClipboardStyle.rowHeightText
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ClipboardRowView()
    }

    /// 数据变了要清掉悬停行，否则旧行号会指向新内容，高亮错位。
    public func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? ClipboardRowView)?.isHovered =
            (tableView as? HoveringTableView)?.hoveredRow == row
    }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let cell = ClipboardCellView.dequeue(from: tableView)
        cell.configure(with: items[row], media: media, thumbnails: thumbnails)
        return cell
    }

    public func highlight(row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    public var query: String { searchField?.stringValue ?? "" }
    public func clearQuery() { searchField?.stringValue = "" }
}

/// 自画选中/悬停背景。系统高亮在磨砂浅底上对比度不够，且深色面板时代留下的
/// 白字方案会糊成一片，所以两者都自己画。
@MainActor
final class ClipboardRowView: NSTableRowView {
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        if isSelected {
            ClipboardStyle.selection.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1),
                         xRadius: 5, yRadius: 5).fill()
        } else if isHovered {
            // 悬停比选中淡得多：鼠标划过是"预览"，键盘选中才是"当前项"
            ClipboardStyle.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1),
                         xRadius: 5, yRadius: 5).fill()
        }
    }
}

/// 跟踪鼠标悬停行的表格。
///
/// 用 NSTrackingArea 而不是 NSEvent.addLocalMonitorForEvents：
/// 后者在 Swift 6 里 handler 是 @Sendable，而 NSEvent 不 conform Sendable，
/// 编译就过不去（M1 踩过）。
@MainActor
final class HoveringTableView: NSTableView {
    var hoveredRow: Int = -1 {
        didSet {
            guard hoveredRow != oldValue else { return }
            applyHover(oldValue, false)
            applyHover(hoveredRow, true)
        }
    }
    private var tracking: NSTrackingArea?

    private func applyHover(_ row: Int, _ on: Bool) {
        guard row >= 0 else { return }
        (rowView(atRow: row, makeIfNecessary: false) as? ClipboardRowView)?.isHovered = on
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { refreshHover(event) }
    override func mouseDragged(with event: NSEvent) { refreshHover(event) }

    override func mouseExited(with event: NSEvent) { hoveredRow = -1 }

    override func reloadData() {
        // 只重置索引，**不要**在这里去碰 row view：
        // reloadData 期间表还没重算布局，调 rowView(atRow:) 会让表格停止渲染行
        // （实测：数据库有 3 条，面板却一片空白）。
        // 新出现的行由 didAdd rowView 回调按当前 hoveredRow 赋值。
        if hoveredRow != -1 { hoveredRow = -1 }
        super.reloadData()
    }

    private func refreshHover(_ event: NSEvent) {
        hoveredRow = row(at: convert(event.locationInWindow, from: nil))
    }
}

/// 一行：内容摘要（或缩略图/文件图标）+ 右侧 chevron。
@MainActor
public final class ClipboardCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("clipboard.cell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var boundSHA: String?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13)
        title.textColor = ClipboardStyle.primaryText
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.backgroundColor = .clear

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = ClipboardStyle.chevron
        chevron.imageScaling = .scaleNone

        addSubview(icon)
        addSubview(title)
        addSubview(chevron)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor,
                                          constant: ClipboardStyle.inset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor,
                                              constant: -ClipboardStyle.inset),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持从 nib 构造") }

    func configure(with item: ClipboardItem, media: MediaStore?,
                   thumbnails: ThumbnailCache) {
        boundSHA = item.mediaSHA256
        title.stringValue = item.rowTitle
        toolTip = item.tooltipDetail
        title.textColor = ClipboardStyle.primaryText

        switch item.kind {
        case .image:
            icon.image = nil
            iconWidth(ClipboardStyle.thumbnail)
            if let sha = item.mediaSHA256, let media {
                _ = thumbnails.image(forSHA: sha, from: media, maxPixel: 160) { [weak self] img in
                    // 复用池里的 cell 可能已被派给别的行，回来时必须再核对
                    guard let self, self.boundSHA == sha else { return }
                    self.icon.image = img
                }
            }
        case .fileURLs:
            iconWidth(18)
            icon.image = NSImage(systemSymbolName: "doc", accessibilityDescription: "文件")
            icon.contentTintColor = ClipboardStyle.secondaryText
        case .text:
            iconWidth(18)
            icon.image = nil
        }
    }

    private var widthConstraint: NSLayoutConstraint?
    private func iconWidth(_ w: CGFloat) {
        widthConstraint?.isActive = false
        let c = icon.widthAnchor.constraint(equalToConstant: w)
        c.isActive = true
        widthConstraint = c
    }

    static func dequeue(from table: NSTableView) -> ClipboardCellView {
        if let reused = table.makeView(withIdentifier: reuseID, owner: nil) as? ClipboardCellView {
            return reused
        }
        let cell = ClipboardCellView(frame: .zero)
        cell.identifier = reuseID
        return cell
    }
}

/// 缩略图缓存：读盘 + 降采样放后台，面板首帧不被它拖住。
///
/// 回调一律留在 MainActor 侧的字典里，跨任务边界只传 sha（值类型）。
/// 直接把 `@MainActor` 闭包带进 `Task.detached` 会被 Swift 6 的 sending 检查拦下。
@MainActor
public final class ThumbnailCache {
    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: Set<String> = []
    private var waiters: [String: [@MainActor (NSImage) -> Void]] = [:]

    public init() { cache.countLimit = 300 }

    public func image(forSHA sha: String, from media: MediaStore, maxPixel: CGFloat = 72,
                      onReady: @escaping @MainActor (NSImage) -> Void) -> NSImage? {
        if let hit = cache.object(forKey: sha as NSString) { return hit }
        waiters[sha, default: []].append(onReady)
        guard !inFlight.contains(sha) else { return nil }
        inFlight.insert(sha)
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

extension ClipboardItem {
    /// 行内显示的摘要。对齐快贴：文本就是文本本身，图片不显示文字，文件带前缀。
    var rowTitle: String {
        switch kind {
        case .text:
            return folded((text ?? "").replacingOccurrences(of: "\t", with: " "))
        case .image:
            return ""
        case .fileURLs:
            let names = (fileURLs ?? []).map(\.lastPathComponent)
            guard let first = names.first else { return "[文件]" }
            return names.count > 1 ? "[文件] \(first) 等 \(names.count) 项" : "[文件] \(first)"
        }
    }

    /// 悬停时给出完整信息（列表里放不下，但不能丢）
    var tooltipDetail: String {
        let source = sourceAppName ?? sourceBundleID ?? "未知来源"
        let head = kind == .image ? "图片" : rowTitle
        return "\(head)\n来源：\(source) · 复制于 \(RelativeTime.short(lastCopiedAt))"
            + (copyCount > 1 ? " · 共 \(copyCount) 次" : "")
    }

    private func folded(_ s: String) -> String {
        let oneLine = s.split(separator: "\n", omittingEmptySubsequences: false)
                        .joined(separator: " ")
        return oneLine
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
