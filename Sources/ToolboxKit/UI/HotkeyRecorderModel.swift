import Foundation

/// 快捷键录制状态机。刻意不依赖 NSView/NSEvent，这样"什么算合法键位、
/// Esc 该回滚成什么、拒绝时提示什么"全部可单测；视图层只负责把按键转成 KeyCombo 喂进来。
public struct HotkeyRecorderModel {
    public private(set) var value: KeyCombo
    public private(set) var pending: KeyCombo?
    public private(set) var rejectedMessage: String?
    public private(set) var isRecording = false
    /// commit() 成功后写入；未提交则为 nil，供调用方区分"用户按了回车"和"什么都没发生"。
    public private(set) var committed: KeyCombo?

    public init(initial: KeyCombo) { self.value = initial }

    public mutating func beginRecording() {
        isRecording = true
        pending = nil
        rejectedMessage = nil
        committed = nil
    }

    public mutating func keyPressed(_ combo: KeyCombo) {
        guard isRecording else { return }
        guard combo.isValidBinding else {
            pending = nil
            rejectedMessage = "需要 \(KeyCombo.requiredModifierHint) 至少一个修饰键；"
                + "功能键（F1–F3）与方向键可以裸按。"
            return
        }
        pending = combo
        rejectedMessage = nil
    }

    public mutating func escape() {
        pending = nil
        rejectedMessage = nil
        isRecording = false
    }

    /// 返回本次新值；没有待提交内容时返回 nil 且保持原值。
    @discardableResult
    public mutating func commit() -> KeyCombo? {
        guard let p = pending else { isRecording = false; return nil }
        value = p
        committed = p
        pending = nil
        isRecording = false
        return p
    }
}

extension KeyCombo {
    /// 用转义写，避免 ⌥ 这类字形在传输/编辑环节被吞掉。
    /// ⌘ U+2318 · U+2325 · ⌃ U+2303 · ⇧ U+21E7
    public static let requiredModifierHint = "\u{2318} / \u{2325} / \u{2303}"
}
