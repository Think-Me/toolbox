import AppKit
import SwiftUI

/// 录制中充当 first responder 收 keyDown 的桥接视图。
/// 比全局事件 monitor 好的地方：键盘只进这一处，不会串到别的控件，
/// 也不会因为 SDK 把 monitor handler 标成 @Sendable 而撞上 NSEvent 非 Sendable 的编译错误。
@MainActor
final class KeyCatcherNSView: NSView {
    var onKey: ((NSEvent) -> Void)?
    var wantsKey = false {
        didSet {
            guard wantsKey else { return }
            window?.makeFirstResponder(self)
        }
    }

    override var acceptsFirstResponder: Bool { wantsKey }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsKey { window?.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        guard wantsKey else { super.keyDown(with: event); return }
        onKey?(event)          // 不转给系统，避免 beep
    }

    /// 录制时吞掉 ⌘ 组合键的菜单匹配，否则 ⌘, 会被"设置…"菜单项截走。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if wantsKey { onKey?(event); return true }
        return super.performKeyEquivalent(with: event)
    }
}

struct KeyCatcher: NSViewRepresentable {
    var active: Bool
    var onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> KeyCatcherNSView {
        let v = KeyCatcherNSView()
        v.onKey = onKey
        return v
    }

    func updateNSView(_ v: KeyCatcherNSView, context: Context) {
        v.onKey = onKey
        v.wantsKey = active
        if active {
            // 必须等这一轮 SwiftUI 把视图挂进窗口层级之后再抢 first responder；
            // 在 didSet 里同步调用时 view.window 常常还是 nil，表现为"进入录制态但收不到按键"。
            DispatchQueue.main.async {
                guard let win = v.window else { return }
                if win.firstResponder !== v { win.makeFirstResponder(v) }
            }
        }
    }
}
