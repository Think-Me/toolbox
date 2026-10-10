import Carbon.HIToolbox
import Foundation

/// 面板里的选中行管理。
///
/// 单独抽出来是因为这类 off-by-one（列表缩了 index 越界、过滤后旧 index 指向
/// 另一条内容、⌘9 数到不存在的行）在真机上很难复现，只能靠测试兜住。
/// 纯值类型、不碰 AppKit，所以不标 @MainActor。
public struct ClipboardListSelection: Equatable {
    public private(set) var index: Int
    public private(set) var count: Int

    public init(count: Int) {
        self.count = max(0, count)
        self.index = 0
    }

    public var isValid: Bool { count > 0 && index < count }

    public mutating func setCount(_ n: Int) {
        count = max(0, n)
        if index >= count { index = max(0, count - 1) }
    }

    /// 过滤条件变了：行集整个换掉，旧 index 会指向毫不相干的条目，所以回顶。
    public mutating func applyFilter(count n: Int) {
        count = max(0, n)
        index = 0
    }

    public mutating func move(_ delta: Int) {
        guard count > 0 else { index = 0; return }
        // 取模两次：Swift 的 % 对负数返回负值
        index = ((index + delta) % count + count) % count
    }

    public mutating func select(_ i: Int) {
        guard count > 0 else { index = 0; return }
        index = min(max(i, 0), count - 1)
    }

    /// 数字键键码 → 数字。**不能按区间算**：kVK_ANSI_* 是 QWERTY 物理列序，
    /// 1..4 是 18..21，但 5=23、6=22、7=28、8=26、9=25。
    /// 按 `keyCode - kVK_ANSI_1` 算会让 ⌘5～⌘9 全部错位（测试实测抓到）。
    static let digitKeyCodes: [UInt16: Int] = [
        UInt16(kVK_ANSI_1): 1, UInt16(kVK_ANSI_2): 2, UInt16(kVK_ANSI_3): 3,
        UInt16(kVK_ANSI_4): 4, UInt16(kVK_ANSI_5): 5, UInt16(kVK_ANSI_6): 6,
        UInt16(kVK_ANSI_7): 7, UInt16(kVK_ANSI_8): 8, UInt16(kVK_ANSI_9): 9,
    ]

    /// ⌘1…⌘9 快粘。⌘0 故意不支持：它既不是"第 10 行"，也不该静默选中没高亮的东西。
    public func quickPick(keyCode: UInt16) -> Int? {
        guard let digit = Self.digitKeyCodes[keyCode] else { return nil }
        let target = digit - 1
        return target < count ? target : nil
    }

    /// 该行对应的 `⌘数字` 标号；超出 1…9 的行返回 nil。
    ///
    /// 界面上必须在行首显示这个标号，否则用户要一个个数字去数才知道按哪个。
    /// 反过来也不能给第 10 行标 "10" —— 那等于暗示存在 ⌘10，而它不存在。
    public static func quickPickLabel(row: Int) -> String? {
        guard (0..<9).contains(row) else { return nil }
        return "\(row + 1)"
    }

    public func current<T>(in items: [T]) -> T? {
        guard isValid, index < items.count else { return nil }
        return items[index]
    }
}
