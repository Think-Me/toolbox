import AppKit

/// 非模态的降级提示条。
///
/// 为什么不用 NSAlert：粘贴失败时面板已经关掉、焦点刚还给目标 App，
/// 这时候弹模态框会把用户的输入流打断，比不提示更糟。
@MainActor
public final class DegradeNotice {
    public static let shared = DegradeNotice()

    private var window: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    public init() {}

    public func show(_ text: String, duration: TimeInterval = 3.0) {
        hideWorkItem?.cancel()
        let panel = window ?? makePanel()
        panel.contentView?.subviews.first?.setAccessibilityLabel(text)
        (panel.contentView?.subviews.compactMap { $0 as? NSTextField }.first)?.stringValue = text
        let screen = NSScreen.main?.frame ?? .zero
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2,
                                     y: screen.minY + 96))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 34),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSView(frame: p.contentView!.bounds)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 0.94).cgColor
        host.layer?.cornerRadius = 8
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        p.contentView = host
        window = p
        return p
    }

}
