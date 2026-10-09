import AppKit

/// NSMenuItem 的 representedObject 只能放 Any?，用一个盒子装 Swift 枚举。
@MainActor
final class ActionBox: NSObject {
    let action: MenuItemSpec.Action
    init(_ action: MenuItemSpec.Action) { self.action = action }
}

@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    public struct State {
        public var settings: AppSettings
        public var recording: Bool
        public var loginItemEnabled: Bool
        public var hosts: HostsMenuSnapshot
        public init(settings: AppSettings, recording: Bool, loginItemEnabled: Bool,
                    hosts: HostsMenuSnapshot = .empty) {
            self.settings = settings; self.recording = recording
            self.loginItemEnabled = loginItemEnabled; self.hosts = hosts
        }
    }

    private var statusItem: NSStatusItem?
    public private(set) var lastSymbolResolved = false
    private let stateProvider: @MainActor () -> State
    private let actions: AppActions

    public init(state: @escaping @MainActor () -> State, actions: AppActions) {
        self.stateProvider = state
        self.actions = actions
        super.init()
    }

    @discardableResult
    public func install() -> Bool {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return false }
        let symbol = NSImage(systemSymbolName: "square.stack.3d.up",
                             accessibilityDescription: "Toolbox")
        // SF Symbol 取不到时返回 nil；只设 image 不设 title 的话，
        // 状态项会"安装成功但一个像素都不画"，且没有任何报错。
        if let symbol {
            symbol.isTemplate = true
            button.image = symbol
        } else {
            button.title = "TBX"
        }
        lastSymbolResolved = symbol != nil
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        return true
    }

    /// 状态栏图标是否真的可见。带刘海的 MacBook 菜单栏被第三方图标占满时，系统会
    /// **静默不建窗口**：install() 照样返回 true、button.window.frame 照样有值、
    /// isVisible 照样 true，但用户在屏上找不到图标（实测：分到的位置 854..892 被刘海吃掉，
    /// layer=25 的窗口列表里没有本进程任何窗口）。所以不能拿 install() 的返回值当"看得见"。
    public func probeReport() -> String {
        guard let item = statusItem, let button = item.button,
              let win = button.window else {
            return "MENUBAR: 状态项未安装（button/window 为 nil）\n"
        }
        let f = win.frame
        let intersects = NSScreen.screens.contains { $0.frame.intersects(f) }
        let shown = win.occlusionState.contains(.visible)
        let hasImage = button.image != nil
        let title = button.title
        let hidden = button.isHidden
        let lvl = win.level.rawValue
        let alpha = win.alphaValue
        let thickness = NSStatusBar.system.thickness
        let count = NSScreen.screens.count
        let mainWidth = NSScreen.main.map { String(describing: $0.frame.width) } ?? "nil"
        let notch = NSScreen.main.map { String(describing: $0.safeAreaInsets.top) } ?? "nil"
        var lines: [String] = []
        lines.append("MENUBAR: frame=\(f) appKitVisible=\(win.isVisible) 与某屏相交=\(intersects)")
        lines.append("  occlusion含可见=\(shown) symbol解析成功=\(lastSymbolResolved) hasImage=\(hasImage) title=\"\(title)\" isHidden=\(hidden)")
        lines.append("  level=\(lvl) alpha=\(alpha) thickness=\(thickness) screens=\(count) 主屏宽=\(mainWidth) 刘海高=\(notch)")
        lines.append("  判定=\(shown ? "图标已显示" : "图标被系统隐藏（菜单栏已满）")\n")
        return lines.joined(separator: "\n")
    }

    /// 给 App 用的判定：图标到底可不可见。
    public var isStatusItemVisible: Bool {
        guard let button = statusItem?.button, let win = button.window else { return false }
        return win.occlusionState.contains(.visible)
    }

    /// 把真正交给 AppKit 的 NSMenu 内容打印出来。
    /// 这是"菜单对不对"的权威验证：MenuItemSpec 的单测只锁纯数据，
    /// Carbon 位掩码 → NSEvent.ModifierFlags 的转换、state 勾选、submenu 都只有在这里才看得见。
    public func dumpMenu() -> String {
        guard let menu = statusItem?.menu else { return "MENU: 未安装\n" }
        menuNeedsUpdate(menu)
        var out: [String] = []
        for (i, mi) in menu.items.enumerated() {
            if mi.isSeparatorItem { out.append("  [\(i)] ---"); continue }
            let mask = mi.keyEquivalentModifierMask
                .intersection([.control, .option, .shift, .command])
                .rawValue
            let sub = mi.submenu.map { " submenu=[\($0.items.map(\.title).joined(separator: ","))]" } ?? ""
            out.append("  [\(i)] \(mi.title) key=\"\(mi.keyEquivalent)\" "
                     + "mask=\(mask) state=\(mi.state.rawValue) enabled=\(mi.isEnabled)\(sub)")
        }
        return "MENU (\(menu.items.count) 项):\n" + out.joined(separator: "\n") + "\n"
    }

    /// 直接把菜单弹在指定位置。用来在"状态项被系统隐藏"的机器上验证菜单本身，
    /// 也留给将来做"右键菜单栏 = 同样菜单"的一致性检查。
    public func popUpPreviewMenu(at screenPoint: NSPoint) {
        guard let item = statusItem else { return }
        let menu = item.menu ?? NSMenu()
        menuNeedsUpdate(menu)
        menu.popUp(positioning: nil, at: screenPoint, in: nil)
    }

    public func remove() {
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
    }

    /// 每次打开都重建：设置、暂停态、登录项状态都会变，缓存菜单必然出现陈旧勾选。
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let st = stateProvider()
        for spec in MenuBuilder.items(settings: st.settings, recording: st.recording,
                                      loginItemEnabled: st.loginItemEnabled, hosts: st.hosts) {
            menu.addItem(make(spec))
        }
    }

    private func make(_ spec: MenuItemSpec) -> NSMenuItem {
        if spec.isSeparator { return .separator() }
        let mi = NSMenuItem(title: spec.title,
                            action: #selector(handle(_:)),
                            keyEquivalent: spec.keyEquivalent ?? "")
        mi.target = self
        mi.representedObject = ActionBox(spec.action)
        if let mask = spec.keyEquivalentMask { mi.keyEquivalentModifierMask = Self.appKitMask(mask) }
        if spec.keyEquivalent == nil { mi.keyEquivalentModifierMask = [] }
        mi.state = spec.checked ? .on : .off
        if case .disabledPlaceholder = spec.action { mi.isEnabled = false }
        if !spec.children.isEmpty {
            let sub = NSMenu()
            sub.autoenablesItems = false
            for child in spec.children { sub.addItem(make(child)) }
            mi.submenu = sub
        }
        return mi
    }

    /// Carbon 位掩码 ≠ NSEvent.ModifierFlags，必须显式转换。
    static func appKitMask(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbon & KeyCombo.control != 0 { f.insert(.control) }
        if carbon & KeyCombo.option  != 0 { f.insert(.option) }
        if carbon & KeyCombo.shift   != 0 { f.insert(.shift) }
        if carbon & KeyCombo.cmd     != 0 { f.insert(.command) }
        return f
    }

    @objc private func handle(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        switch box.action {
        case .hotkey(let id):     actions.invoke(id)
        case .togglePause:        actions.togglePause()
        case .openPermissions:    actions.openPermissions()
        case .openSettings:       actions.openSettings()
        case .toggleLoginItem:    actions.toggleLoginItem()
        case .hostsToggle(let id): actions.hostsToggle(id)
        case .hostsManagementToggle: actions.hostsManagementToggle()
        case .quit:               actions.quit()
        case .separator, .disabledPlaceholder: break
        }
    }
}
