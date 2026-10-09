import AppKit
import STTextView
import SwiftUI

/// hosts 规则编辑器。
///
/// 用 STTextView 而不是 NSTextView：自带行号、代码字体、大文件不卡。
/// 语法着色这版没做（需要额外的 tokenizer 插件），行号 + 等宽已覆盖
/// "看清哪条规则对应哪行"的实际需求。
///
/// 关键一点：STTextView 的编辑变化**只通过 delegate 通知**，不会自动写回
/// SwiftUI 的 Binding。所以必须由 coordinator 把新文本回吐给调用方，
/// 否则会出现"改了内容但 hasUnsavedContent 永远 false、保存按钮永远灰着"
/// （上一版就是这么错的）。
@MainActor
struct HostsEditorTextView: NSViewRepresentable {
    @Binding var text: String
    var isReadOnly: Bool = false
    /// 用户编辑后回调，携带编辑器里的最新文本
    var onTextChange: (String) -> Void

    init(text: Binding<String>, isReadOnly: Bool = false,
         onTextChange: @escaping (String) -> Void) {
        self._text = text
        self.isReadOnly = isReadOnly
        self.onTextChange = onTextChange
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = STTextView()
        tv.showsLineNumbers = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isEditable = !isReadOnly
        tv.text = text
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? STTextView else { return }
        context.coordinator.onTextChange = onTextChange
        tv.isEditable = !isReadOnly
        // STTextView.text 是 String?
        guard !context.coordinator.isApplyingExternalChange else { return }
        if tv.text != text {
            context.coordinator.isApplyingExternalChange = true
            tv.text = text
            context.coordinator.isApplyingExternalChange = false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange)
    }

    final class Coordinator: NSObject, STTextViewDelegate {
        weak var textView: STTextView?
        var onTextChange: (String) -> Void
        var isApplyingExternalChange = false

        init(onTextChange: @escaping (String) -> Void) {
            self.onTextChange = onTextChange
        }

        func textViewDidChangeText(_ notification: Notification) {
            guard !isApplyingExternalChange, let tv = textView else { return }
            onTextChange(tv.text ?? "")
        }
    }
}
