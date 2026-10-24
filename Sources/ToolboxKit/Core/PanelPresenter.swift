import AppKit

public enum PanelAnchor: Equatable, Sendable {
    case cursor, screenCenter, previousAppWindow
}

public enum DismissReason: Equatable, Sendable {
    case clickOutside, escape, chose, explicitClose
}

enum ScreenResolver {
    static func screen(containing point: CGPoint) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

/// 浮层生命周期：记住呼出前的前台 App → 弹出 → 四种出口统一收口关闭。
///
/// 全程**不调 `NSApp.activate`**：这是"粘贴回原 App"能成立的前提。
/// 需要把 App 拉到前台的只有设置窗口（见 SettingsWindowController），别照抄到这里。
@MainActor
public final class PanelPresenter {
    public static let shared = PanelPresenter()

    public private(set) var isShowing = false
    public private(set) var frontAppBeforePresentation: NSRunningApplication?
    /// 钉住时点击面板外不关闭（翻译浮窗用）；Esc 仍可关闭。
    public private(set) var isPinned = false

    private var panel: FloatingPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onDismiss: (@MainActor (DismissReason) -> Void)?

    public init() {}

    /// 当前浮层窗口。控制器要往里设 first responder（比如让搜索框拿到键盘）。
    /// 只读：外部不该换窗口。
    public var windowForFocus: NSWindow? { panel }

    public func show<V: NSView>(content: V, anchor: PanelAnchor,
                                width: CGFloat, height: CGFloat,
                                onDismiss: @escaping @MainActor (DismissReason) -> Void) {
        dismissCurrent(reason: .chose)
        frontAppBeforePresentation = NSWorkspace.shared.frontmostApplication
        self.onDismiss = onDismiss

        let p = FloatingPanel(width: width, height: height)
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        p.contentView = content

        let cursor = NSEvent.mouseLocation
        let screen = ScreenResolver.screen(containing: cursor)
        let origin: CGPoint
        switch anchor {
        case .cursor, .previousAppWindow: origin = cursor
        case .screenCenter: origin = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        }
        p.setFrame(PanelPositioner.rect(width: width, height: height, cursor: origin,
                                        screenFrame: screen.frame,
                                        visibleFrame: screen.visibleFrame),
                   display: false)
        p.makeKeyAndOrderFront(nil)

        isPinned = false
        installOutsideMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == PanelPresenter.escapeKeyCode else { return event }
            MainActor.assumeIsolated { PanelPresenter.shared.dismissCurrent(reason: .escape) }
            return nil
        }
        panel = p
        isShowing = true
    }

    static let escapeKeyCode: UInt16 = 53

    /// 钉住/取消钉住：只切"点外面是否关闭"，Esc 始终有效。
    public func setPinned(_ pinned: Bool) {
        guard isShowing else { return }
        isPinned = pinned
        if pinned {
            removeOutsideMonitor()
        } else if globalMonitor == nil {
            installOutsideMonitor()
        }
    }

    /// 点面板外的统一出口：钉住时忽略。抽出来是为了探针能直接验证这套规则。
    public func handleOutsideClick() {
        guard isShowing, !isPinned else { return }
        dismissCurrent(reason: .clickOutside)
    }

    /// 探针用：确认钉住时监听确实被摘掉、取消后又装回来。
    public var outsideMonitorInstalled: Bool { globalMonitor != nil }

    private func installOutsideMonitor() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { PanelPresenter.shared.handleOutsideClick() }
        }
    }

    private func removeOutsideMonitor() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
    }

    /// 内容变多/变少时按需改尺寸（翻译浮窗用）。
    /// 固定顶边而不是中心：面板从光标下方展开，高度变化时上沿不动看起来才不跳。
    public func resize(width: CGFloat, height: CGFloat) {
        guard let panel else { return }
        let old = panel.frame
        let screen = ScreenResolver.screen(containing: NSPoint(x: old.midX, y: old.midY))
        var frame = NSRect(x: old.minX, y: old.maxY - height, width: width, height: height)
        let visible = screen.visibleFrame
        frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - height))
        frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - width))
        panel.setFrame(frame, display: true)
    }

    /// 四种出口（点窗外 / Esc / 选中 / ⌘W）必须都走这里，
    /// 否则漏一次 orderOut 就会留下看不见但吃事件的浮层。
    public func dismissCurrent(reason: DismissReason) {
        guard isShowing || panel != nil else { return }
        removeOutsideMonitor()
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        localMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        isShowing = false
        isPinned = false
        let cb = onDismiss
        onDismiss = nil
        cb?(reason)
    }
}
