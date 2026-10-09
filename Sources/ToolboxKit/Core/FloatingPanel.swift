import AppKit

/// 热键呼出的无边框浮层。三个模块共用（剪贴板列表 / Hosts 快切 / 截图操作条）。
@MainActor
public final class FloatingPanel: NSPanel {
    public init(width: CGFloat, height: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovable = false
        // 不开这个，NSTrackingArea 的 .mouseMoved 不会投递，悬停高亮就不跟手
        acceptsMouseMovedEvents = true
        // 尺寸由 contentRect 与后续 setFrame 决定；不给窗口自身加宽高约束，
        // 否则和 setFrame 抢，表现为面板尺寸弹不回。
    }

    /// LSUIElement 的 App 里 borderless panel 想拿到键盘焦点，必须显式放开。
    /// 仍返回 false：浮层不是"主窗口"，抢了主窗口会把 App 拉成前台。
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}
