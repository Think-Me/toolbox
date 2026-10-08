import AppKit

/// "把前台切过去"和"发一次 ⌘V"这两件只能对真系统做的事，抽成协议。
///
/// 为什么要抽：合成按键受焦点状态、别家全局热键截胡、发送方权限影响，
/// 在单测里时灵时不灵（M0 期间实测踩过）。逻辑契约（先写剪贴板再切前台、
/// 权限缺失要降级而不是失败）用假实现就能 100% 确定地测；
/// 真粘贴成功率留给 docs/manual-qa.md 的五个宿主手工验证。
@MainActor
public protocol PasteDriving: AnyObject {
    /// 返回前台是否真的切到位（超时算 false）
    func activate(_ app: NSRunningApplication?) async -> Bool
    func sendPasteKeystroke() async -> Bool
}

/// 真实现。
@MainActor
public final class SystemPasteDriver: PasteDriving {
    /// ⌘V 的虚拟键码
    static let vKeyCode: UInt16 = 9
    static let activationTimeout: TimeInterval = 0.3
    static let pollInterval: UInt64 = 10_000_000     // 10ms

    public init() {}

    /// 轮询等前台到位，而不是固定 sleep：
    /// 固定 sleep 在慢 App（IDE、浏览器多标签）上会在焦点还没过来时就发键，
    /// 结果是粘到了错误的窗口 —— 比不粘更糟。
    public func activate(_ app: NSRunningApplication?) async -> Bool {
        guard let app else { return false }
        app.activate()
        let deadline = Date().addingTimeInterval(Self.activationTimeout)
        while Date() < deadline {
            if Self.isFrontmost(app) { return true }
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
        return Self.isFrontmost(app)
    }

    private static func isFrontmost(_ app: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    public func sendPasteKeystroke() async -> Bool {
        guard let src = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(Self.vKeyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(Self.vKeyCode), keyDown: false)
        else { return false }
        down.flags = CGEventFlags.maskCommand
        up.flags = CGEventFlags.maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
