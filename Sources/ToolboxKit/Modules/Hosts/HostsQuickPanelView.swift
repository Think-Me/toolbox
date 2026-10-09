import AppKit
import Carbon.HIToolbox

/// `⌘⇧H` 的 Hosts 快速切换浮层。
///
/// 勾选**不立即写盘**：连点 5 条规则只该产生 1 次 hosts 写入 + 1 次 DNS 刷新。
/// 每次点击就写系统文件既慢又危险（中途失败会留下半套状态）。
@MainActor
public final class HostsQuickPanelView: NSView {
    public struct Row: Equatable {
        public let id: UUID
        public let group: String
        public let name: String
        public var enabled: Bool
        public let kindLabel: String
        public init(id: UUID, group: String, name: String, enabled: Bool, kindLabel: String) {
            self.id = id; self.group = group; self.name = name
            self.enabled = enabled; self.kindLabel = kindLabel
        }
    }

    private let table = NSTableView()
    private let search = NSSearchField()
    private(set) public var rows: [Row] = []
    private var filtered: [Row] = []
    private var pendingToggles = Set<UUID>()
    public var onChanged: (([UUID]) -> Void)?
    public var onCancel: (() -> Void)?

    public init(width: CGFloat = 360, height: CGFloat = 380) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        appearance = NSAppearance(named: .aqua)
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        let effect = NSVisualEffectView()
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        addSubview(effect, positioned: .below, relativeTo: nil)

        search.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "搜索规则"
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 12)
        search.target = self
        search.action = #selector(searchChanged)
        addSubview(search)

        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("h")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
        addSubview(scroll)

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            search.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持从 nib 构造") }

    public func load(_ newRows: [Row]) {
        rows = newRows
        applyFilter()
    }

    /// 关闭时把攒下的勾选一次性交出去。
    public func flushPending() {
        guard !pendingToggles.isEmpty else { return }
        let ids = Array(pendingToggles)
        pendingToggles.removeAll()
        onChanged?(ids)
    }

    private func applyFilter() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        filtered = q.isEmpty ? rows : rows.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.group.localizedCaseInsensitiveContains(q)
        }
        table.reloadData()
    }

    @objc private func searchChanged() { applyFilter() }

    @objc private func rowClicked() { toggle(row: table.clickedRow) }

    private func toggle(row index: Int) {
        guard filtered.indices.contains(index) else { return }
        let id = filtered[index].id
        filtered[index].enabled.toggle()
        if let ri = rows.firstIndex(where: { $0.id == id }) {
            rows[ri].enabled = filtered[index].enabled
        }
        if pendingToggles.contains(id) { pendingToggles.remove(id) } else { pendingToggles.insert(id) }
        table.reloadData()
    }

    public override var acceptsFirstResponder: Bool { true }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case UInt16(kVK_ANSI_A):
            if event.modifierFlags.contains(.command) {
                pendingToggles.formUnion(rows.map(\.id))
                for i in rows.indices { rows[i].enabled = true }
                applyFilter()
            }
        case UInt16(kVK_Space):
            toggle(row: table.selectedRow >= 0 ? table.selectedRow : 0)
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            flushPending()
            onCancel?()
        case UInt16(kVK_Escape):
            // 放弃未应用的改动
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }
}

extension HostsQuickPanelView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                          row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("hosts.row")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? HostsRowCell)
            ?? { let c = HostsRowCell(); c.identifier = id; return c }()
        guard filtered.indices.contains(row) else { return cell }
        cell.configure(with: filtered[row])
        return cell
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
}

@MainActor
final class HostsRowCell: NSTableCellView {
    private let check = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let kind = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        check.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingHead
        kind.translatesAutoresizingMaskIntoConstraints = false
        kind.font = .systemFont(ofSize: 10)
        kind.textColor = .tertiaryLabelColor
        addSubview(check); addSubview(title); addSubview(kind)
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            kind.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            kind.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            kind.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with row: HostsQuickPanelView.Row) {
        check.image = NSImage(systemSymbolName: row.enabled ? "checkmark.square.fill" : "square",
                              accessibilityDescription: row.enabled ? "已启用" : "未启用")
        check.contentTintColor = row.enabled ? .controlAccentColor : .tertiaryLabelColor
        title.stringValue = "\(row.group) › \(row.name)"
        title.textColor = row.enabled ? .labelColor : .secondaryLabelColor
        kind.stringValue = row.kindLabel
    }
}
