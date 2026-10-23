import Carbon.HIToolbox
import AppKit

/// 一个全局快捷键绑定。keyCode 用 `NSEvent.keyCode` 的口径（UInt16），
/// 传给 RegisterEventHotKey 时才转 UInt32 —— 实测约束，别把存储类型改掉。
public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var carbonModifiers: UInt32

    public init(keyCode: UInt16, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    // Carbon 修饰键位
    public static let control: UInt32 = UInt32(controlKey)
    public static let option:  UInt32 = UInt32(optionKey)
    public static let shift:   UInt32 = UInt32(shiftKey)
    public static let cmd:     UInt32 = UInt32(cmdKey)
    /// shift 不算数：裸 shift+字母 不是可用的全局快捷键
    public static let requiredMask: UInt32 = control | option | cmd

    // 常用虚拟键码
    public static let ansiA: UInt16 = 0, ansiS: UInt16 = 1, ansiD: UInt16 = 2, ansiF: UInt16 = 3
    public static let ansiH: UInt16 = 4, ansiT: UInt16 = 17, ansiV: UInt16 = 9
    public static let comma: UInt16 = 43
    public static let space: UInt16 = 49, deleteLeft: UInt16 = 51, returnKey: UInt16 = 36
    public static let f1: UInt16 = 122, f2: UInt16 = 120, f3: UInt16 = 99
    private static let up: UInt16 = 126, down: UInt16 = 125, left: UInt16 = 123, right: UInt16 = 124

    /// 从 NSEvent 的修饰键推导 Carbon 掩码。
    /// 必须先用 deviceIndependentFlagsMask 取交集：`.capsLock` / `.function` 这类
    /// 设备位不移掉的话，所有 F 键都会带上一个幽灵修饰位，导致注册失败。
    public init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        let m = modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if m.contains(.control) { carbon |= Self.control }
        if m.contains(.option)  { carbon |= Self.option }
        if m.contains(.shift)   { carbon |= Self.shift }
        if m.contains(.command) { carbon |= Self.cmd }
        self.init(keyCode: keyCode, carbonModifiers: carbon)
    }

    /// 至少要有一个非 shift 修饰键；功能键与方向键允许裸按。
    /// 功能键用显式列表而不是 122...129 区间：那个区间会把方向键也算成 F 键，
    /// 结果虽然都合法，但代码读不出"为什么裸按 ← 合法"。
    public var isValidBinding: Bool {
        if carbonModifiers & Self.requiredMask != 0 { return true }
        return isFunctionKey || isArrowOrNavigation
    }
    private var isFunctionKey: Bool { [Self.f1, Self.f2, Self.f3].contains(keyCode) }
    private var isArrowOrNavigation: Bool { [Self.up, Self.down, Self.left, Self.right].contains(keyCode) }

    /// 显示顺序遵循 macOS 规范 ⌃⌥⇧⌘，因此 Shift+Cmd+V 渲染成 "⇧⌘V"。
    public var displayString: String {
        var s = ""
        if carbonModifiers & Self.control != 0 { s += "⌃" }
        if carbonModifiers & Self.option  != 0 { s += "⌥" }
        if carbonModifiers & Self.shift   != 0 { s += "⇧" }
        if carbonModifiers & Self.cmd     != 0 { s += "⌘" }
        return s + Self.keyName(for: keyCode)
    }

    /// 查表来自 SDK 生成的 KeyCodeNames（116 个键码），未知键码必须给出可见兜底，
    /// 否则 UI 上会出现"看不见的快捷键"。
    public static func keyName(for keyCode: UInt16) -> String {
        KeyCodeNames.table[keyCode] ?? "?(\(keyCode))"
    }
}
