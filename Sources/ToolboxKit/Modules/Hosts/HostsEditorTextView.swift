import AppKit
import STTextView
import SwiftUI

/// hosts 规则编辑器。
///
/// 用 STTextView 而不是 NSTextView：自带行号、代码字体、大文件不卡。
/// 语法着色这版没做（需要额外的 tokenizer 插件），行号 + 等宽 + 可编辑已经
/// 覆盖"看清哪条规则对应哪行"的实际需求。
@MainActor
struct HostsEditorTextView: NSViewRepresentable {
    @Binding var text: String
    var isReadOnly: Bool = false
    var onEdit: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let tv = STTextView()
        tv.showsLineNumbers = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isEditable = !isReadOnly
        tv.text = text
        tv.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? STTextView else { return }
        tv.isEditable = !isReadOnly
        // 外部改值（切换选中规则）时才回写，否则会把用户正在打的字覆盖掉
        // STTextView.text 是 String?
        if tv.text != text {
            context.coordinator.isApplyingExternalChange = true
            tv.text = text
            context.coordinator.isApplyingExternalChange = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    final class Coordinator: NSObject, STTextViewDelegate {
        weak var textView: STTextView?
        var isApplyingExternalChange = false
        private let onEdit: () -> Void
        init(onEdit: @escaping () -> Void) { self.onEdit = onEdit }

    func textViewDidChangeText(_ notification: Notification) {
            guard !isApplyingExternalChange, textView != nil else { return }
            onEdit()
        }
    }
}
