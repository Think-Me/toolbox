import AppKit
import SwiftUI

@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let restoreToAccessory: Bool

    public init(model: AppModel) {
        self.model = model
        self.restoreToAccessory = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Toolbox 设置"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: SettingsRootView(model: model))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("不支持从 nib 构造") }

    /// 与 FloatingPanel 相反：设置窗就是要拿到键盘焦点。
    ///
    /// accessory（LSUIElement）App 的普通窗口拿不到键盘，实测 `activate()` 与
    /// `activate(ignoringOtherApps:)` 都无法让窗口成为 key。做法是窗口打开期间临时
    /// 升到 `.regular`（获得完整激活权），窗口关闭后再降回 `.accessory`，
    /// 这样"平时不占 Dock"的形态承诺仍然成立。
    public func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        model.stopRecording()
        // 只有没有其他可见窗口时才降回去，否则会把浮层/贴图也一起变成"不能收键盘"。
        let stillOpen = NSApp.windows.contains {
            $0.isVisible && !($0 is NSPanel) && $0.contentViewController != nil
        }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }

    public var probeLine: String {
        guard let w = window else { return "no window" }
        let policy: String
        switch NSApp.activationPolicy() {
        case .regular: policy = "regular"
        case .accessory: policy = "accessory"
        case .prohibited: policy = "prohibited"
        @unknown default: policy = "?"
        }
        return "isKey=\(w.isKeyWindow) visible=\(w.isVisible) policy=\(policy) "
             + "appActive=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil") "
             + "firstResponder=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") "
             + "frontApp=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")"
    }
}
