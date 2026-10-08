import AppKit
import SwiftUI

/// 设置窗专用窗口。键盘事件统一从 `sendEvent` 漏斗走，而不是依赖某个子视图
/// 抢到 first responder —— 实测后者在 SwiftUI 里不可靠（SwiftUI 会在重绘时
/// 自己改 firstResponder，我们设的会被冲掉，表现为"进入录制态但按什么都没反应"）。
@MainActor
final class RecordingWindow: NSWindow {
    /// 返回 true 表示事件已消费，不再往下传。
    var onKeyEvent: ((NSEvent) -> Bool)?
    var keyEventLog: ((NSEvent) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            keyEventLog?(event)
            if let onKeyEvent, onKeyEvent(event) { return }
        }
        super.sendEvent(event)
    }
}

@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let restoreToAccessory: Bool

    public init(model: AppModel) {
        self.model = model
        self.restoreToAccessory = true
        let window = RecordingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Toolbox 设置"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: SettingsRootView(model: model))
        super.init(window: window)
        window.delegate = self
        let rw = window
        do {
            rw.onKeyEvent = { [weak model] event in
                guard let model, model.isRecording else { return false }
                model.handleRecordedKey(event)
                return true
            }
            rw.keyEventLog = { [weak self] event in
                guard CommandLine.arguments.contains("--keylog") else { return }
                let chars = event.charactersIgnoringModifiers ?? ""
                Self.log("KEYDOWN code=\(event.keyCode) chars=\"\(chars)\" "
                       + "mods=\(event.modifierFlags.rawValue) → 转发给录制器\n")
                _ = self
            }
        }
    }

    static func log(_ s: String) {
        FileHandle.standardError.write(s.data(using: .utf8)!)
    }

    /// 诊断：键盘事件到底有没有送到这个窗口。
    public var focusProbe: String {
        guard let w = window else { return "no window" }
        return "isKey=\(w.isKeyWindow) main=\(NSApp.mainWindow.map { String(describing: type(of: $0)) } ?? "nil") "
             + "keyWindow=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil") "
             + "firstResponder=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") "
             + "appActive=\(NSApp.isActive)"
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
