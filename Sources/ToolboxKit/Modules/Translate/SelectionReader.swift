import AppKit
import ApplicationServices

/// 一次"读取选中文本"的结果。
/// `element` 只在 AX 路径下存在，用于之后把译文写回同一处（替换原文）。
@MainActor
public struct SelectionCapture {
    public enum Source: Equatable, Sendable { case accessibility, copy }
    public var text: String
    public var element: AXUIElement?
    public var source: Source

    public init(text: String, element: AXUIElement? = nil, source: Source) {
        self.text = text
        self.element = element
        self.source = source
    }
}

/// AX 读写选中文本。抽协议是为了让 SelectionReader 的剪贴板/超时逻辑能脱离真系统测试。
@MainActor
public protocol AXSelectionProviding: AnyObject {
    func selectedText() -> (text: String, element: AXUIElement?)?
    func replaceSelection(in element: AXUIElement, with text: String) -> Bool
}

/// 发 ⌘C / ⌘V。
@MainActor
public protocol CommandKeySending: AnyObject {
    func sendCopy() -> Bool
    func sendPaste() -> Bool
}

@MainActor
public final class SystemAXSelection: AXSelectionProviding {
    public init() {}

    public func selectedText() -> (text: String, element: AXUIElement?)? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        let element = focused as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return (text, element)
    }

    public func replaceSelection(in element: AXUIElement, with text: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }
}

/// CGEvent 合成 ⌘C/⌘V。辅助功能权限已由 PermissionCenter 统一申请。
@MainActor
public final class CGCommandSender: CommandKeySending {
    public init() {}

    public func sendCopy() -> Bool { send(keyCode: 8, flags: .maskCommand) }
    public func sendPaste() -> Bool { send(keyCode: 9, flags: .maskCommand) }

    private func send(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let src = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

/// 取词：AX 优先，失败再合成 ⌘C。
///
/// ⌘C 路径必须把剪贴板**原样还回去**：用户可能是为了翻译才复制，但原本剪贴板里
/// 的内容（比如正要粘贴的密码）不能因此被弄丢。还原后还要给 SelfWriteTracker
/// 打一次写入标记，否则 ClipboardMonitor 会在 0.3s 轮询里把这次还原当成新复制。
@MainActor
public final class SelectionReader {
    private let ax: AXSelectionProviding
    private let keys: CommandKeySending
    private let tracker: SelfWriteTracker
    private let pasteboard: NSPasteboard
    private let copyTimeout: TimeInterval

    public init(ax: AXSelectionProviding = SystemAXSelection(),
                keys: CommandKeySending = CGCommandSender(),
                tracker: SelfWriteTracker,
                pasteboard: NSPasteboard = .general,
                copyTimeout: TimeInterval = 0.6) {
        self.ax = ax
        self.keys = keys
        self.tracker = tracker
        self.pasteboard = pasteboard
        self.copyTimeout = copyTimeout
    }

    public func read() async -> SelectionCapture? {
        if let hit = ax.selectedText() {
            let text = hit.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return SelectionCapture(text: text, element: hit.element, source: .accessibility)
            }
        }
        guard let text = await copySelection() else { return nil }
        return SelectionCapture(text: text, source: .copy)
    }

    /// 把译文写回原处。AX 不可写就退回"写剪贴板 + ⌘V"（要求原选区仍在）。
    public func replace(_ capture: SelectionCapture, with text: String) -> Bool {
        if let element = capture.element,
           ax.replaceSelection(in: element, with: text) {
            return true
        }
        tracker.markWrite(at: Date())
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return keys.sendPaste()
    }

    private func copySelection() async -> String? {
        let saved = Self.save(pasteboard)
        let before = pasteboard.changeCount
        // 标记必须打在发键**之前**：否则 0.3s 轮询可能正好落在
        // "⌘C 已生效、还没读到"的空档，把待翻译文本采集进历史。
        tracker.markWrite(at: Date())
        guard keys.sendCopy() else {
            restore(saved)
            return nil
        }
        let deadline = Date().addingTimeInterval(copyTimeout)
        while Date() < deadline {
            if pasteboard.changeCount != before {
                let text = pasteboard.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                restore(saved)
                if let text, !text.isEmpty { return text }
                return nil
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        restore(saved)
        return nil
    }

    private struct Saved {
        var items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func save(_ pb: NSPasteboard) -> Saved {
        let items = (pb.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
        return Saved(items: items)
    }

    private func restore(_ saved: Saved) {
        // 先 clear 再 writeObjects：writeObjects 是追加式，不 clear 会把 ⌘C 的内容留在栈里
        pasteboard.clearContents()
        guard !saved.items.isEmpty else {
            tracker.markWrite(at: Date())
            return
        }
        let items = saved.items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
        tracker.markWrite(at: Date())
    }
}
