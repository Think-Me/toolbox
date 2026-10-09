import Foundation

/// 菜单项的纯数据描述。`MenuBar` 负责把它变成 `NSMenuItem`，
/// 结构本身可单测，用来锁住 spec §6 的菜单契约。
public struct MenuItemSpec: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case hotkey(HotkeyID)
        case togglePause
        case openPermissions
        case openSettings
        case toggleLoginItem
        case hostsToggle(UUID)
        case hostsManagementToggle
        case quit
        case separator
        /// 明确标注"这版还没接"的行，置灰且不可点。
        /// 和"占位符"的区别：它带着版本号，用户知道什么时候会有。
        case disabledPlaceholder
    }

    public var title: String
    public var keyEquivalent: String?
    public var keyEquivalentMask: UInt32?
    public var checked: Bool
    public var isSeparator: Bool
    public var action: Action
    public var children: [MenuItemSpec]

    public init(title: String, keyEquivalent: String? = nil, keyEquivalentMask: UInt32? = nil,
                checked: Bool = false, isSeparator: Bool = false,
                action: Action = .separator, children: [MenuItemSpec] = []) {
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.keyEquivalentMask = keyEquivalentMask
        self.checked = checked
        self.isSeparator = isSeparator
        self.action = action
        self.children = children
    }

    public static let separator = MenuItemSpec(title: "", isSeparator: true)
}

/// 把动作收成一个闭包表，让全局热键和菜单项共用同一份实现。
/// 否则"从菜单点"和"按热键"会走两条代码路径，行为迟早分叉。
@MainActor
public struct AppActions {
    public var clipboard: @MainActor () -> Void
    public var hostsQuick: @MainActor () -> Void
    public var captureRegion: @MainActor () -> Void
    public var captureFull: @MainActor () -> Void
    public var killAllPins: @MainActor () -> Void
    public var togglePause: @MainActor () -> Void
    public var openPermissions: @MainActor () -> Void
    public var openSettings: @MainActor () -> Void
    public var toggleLoginItem: @MainActor () -> Void
    public var hostsToggle: @MainActor (UUID) -> Void
    public var hostsManagementToggle: @MainActor () -> Void
    public var quit: @MainActor () -> Void

    public init(clipboard: @escaping @MainActor () -> Void,
                hostsQuick: @escaping @MainActor () -> Void,
                captureRegion: @escaping @MainActor () -> Void,
                captureFull: @escaping @MainActor () -> Void,
                killAllPins: @escaping @MainActor () -> Void,
                togglePause: @escaping @MainActor () -> Void,
                openPermissions: @escaping @MainActor () -> Void,
                openSettings: @escaping @MainActor () -> Void,
                toggleLoginItem: @escaping @MainActor () -> Void,
                hostsToggle: @escaping @MainActor (UUID) -> Void,
                hostsManagementToggle: @escaping @MainActor () -> Void,
                quit: @escaping @MainActor () -> Void) {
        self.clipboard = clipboard
        self.hostsQuick = hostsQuick
        self.captureRegion = captureRegion
        self.captureFull = captureFull
        self.killAllPins = killAllPins
        self.togglePause = togglePause
        self.openPermissions = openPermissions
        self.openSettings = openSettings
        self.toggleLoginItem = toggleLoginItem
        self.hostsToggle = hostsToggle
        self.hostsManagementToggle = hostsManagementToggle
        self.quit = quit
    }

    /// 按业务 id 触发（热键回调走这条路，保证与菜单同源）。
    public func invoke(_ id: HotkeyID) {
        switch id {
        case .clipboard:     clipboard()
        case .hostsQuick:    hostsQuick()
        case .captureRegion: captureRegion()
        case .captureFull:   captureFull()
        case .killAllPins:   killAllPins()
        case .openSettings:  openSettings()
        }
    }
}

/// 菜单要显示的真实规则快照。传值进来而不是让 MenuBuilder 去读全局状态，
/// 这样它保持纯函数、可单测。
public struct HostsMenuRow: Equatable, Sendable {
    public let id: UUID
    public let group: String
    public let name: String
    public let enabled: Bool
    public init(id: UUID, group: String, name: String, enabled: Bool) {
        self.id = id; self.group = group; self.name = name; self.enabled = enabled
    }
}

public struct HostsMenuSnapshot: Equatable, Sendable {
    public let managementOn: Bool
    public let rows: [HostsMenuRow]
    public init(managementOn: Bool, rows: [HostsMenuRow]) {
        self.managementOn = managementOn; self.rows = rows
    }
    public static let empty = HostsMenuSnapshot(managementOn: true, rows: [])
}

public enum MenuBuilder {

    public static func items(settings: AppSettings, recording: Bool,
                             loginItemEnabled: Bool,
                             hosts: HostsMenuSnapshot = .empty) -> [MenuItemSpec] {
        let out: [MenuItemSpec] = [
            hotkeyItem("剪贴板历史", .clipboard, settings),
            MenuItemSpec(title: "Hosts 规则",
                         keyEquivalent: charAndMask(settings.hotkeys[.hostsQuick]).0,
                         keyEquivalentMask: charAndMask(settings.hotkeys[.hostsQuick]).1,
                         action: .hotkey(.hostsQuick),
                         children: hostsSubmenu(hosts)),
            hotkeyItem("区域截图", .captureRegion, settings),
            hotkeyItem("全屏截图", .captureFull, settings),
            hotkeyItem("关闭所有贴图", .killAllPins, settings),
            .separator,
            MenuItemSpec(title: "暂停剪贴板记录", checked: !recording, action: .togglePause),
            MenuItemSpec(title: "权限与授权", action: .openPermissions),
            // 设置项绑到全局热键：菜单栏图标可能被系统隐藏（刘海 + 图标占满），
            // 没有这个热键，App 在用户机器上就彻底不可达。
            MenuItemSpec(title: "设置与快捷键…",
                         keyEquivalent: charAndMask(settings.hotkeys[.openSettings]).0,
                         keyEquivalentMask: charAndMask(settings.hotkeys[.openSettings]).1,
                         action: .hotkey(.openSettings)),
            MenuItemSpec(title: "登录时启动", checked: loginItemEnabled, action: .toggleLoginItem),
            .separator,
            MenuItemSpec(title: "退出 Toolbox", action: .quit),
        ]
        return out
    }

    /// 子菜单：总开关 + 每条规则一行（勾选即切换）。
    static func hostsSubmenu(_ snapshot: HostsMenuSnapshot) -> [MenuItemSpec] {
        var children = [MenuItemSpec(
            title: snapshot.managementOn ? "Hosts 托管：开" : "Hosts 托管：关",
            checked: snapshot.managementOn, action: .hostsManagementToggle)]
        guard snapshot.managementOn else { return children }
        if snapshot.rows.isEmpty {
            children.append(MenuItemSpec(title: "（还没有规则，去设置里新建）",
                                         action: .disabledPlaceholder))
            return children
        }
        var lastGroup: String?
        for row in snapshot.rows {
            if row.group != lastGroup, lastGroup != nil { children.append(.separator) }
            lastGroup = row.group
            children.append(MenuItemSpec(title: row.name, checked: row.enabled,
                                         action: .hostsToggle(row.id)))
        }
        return children
    }

    private static func hotkeyItem(_ title: String, _ id: HotkeyID,
                                   _ s: AppSettings) -> MenuItemSpec {
        let (ch, mask) = charAndMask(s.hotkeys[id])
        return MenuItemSpec(title: title, keyEquivalent: ch, keyEquivalentMask: mask,
                            action: .hotkey(id))
    }

    /// 只有存在可打印单字符时才能当 `NSMenuItem.keyEquivalent`。
    /// 把 "F2" 塞进去会变成"按 f 就触发"的幽灵快捷键，所以非单字符一律 nil。
    static func charAndMask(_ combo: KeyCombo?) -> (String?, UInt32?) {
        guard let combo else { return (nil, nil) }
        let name = KeyCombo.keyName(for: combo.keyCode)
        guard name.count == 1, let scalar = name.unicodeScalars.first,
              scalar.isASCII else { return (nil, nil) }
        return (name.lowercased(), combo.carbonModifiers)
    }
}
