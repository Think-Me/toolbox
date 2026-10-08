import Foundation

/// 记录"本 App 刚刚写过剪贴板"的时刻。
///
/// 为什么光有 pasteboard 上的自写标记不够：粘贴时目标 App（微信、Office、浏览器）
/// 常常会把 pasteboard 重新写一遍来转换类型，我们打的标记就没了。
/// 于是 monitor 会把自己刚粘出去的内容当成"用户新复制了一条"再采一遍，
/// 表现为 copy_count 虚高、甚至出现近似重复的行（实测一次粘贴让计数 +3）。
/// 所以再加一层时间窗：我们自己写完之后的一小段时间内，任何变化都跳过。
@MainActor
public final class SelfWriteTracker {
    /// 0.6s：足够覆盖目标 App 的类型回写，又短到用户连续两次手动复制不会漏。
    public static let grace: TimeInterval = 0.6

    private var lastWriteAt: Date?

    public init() {}

    public func markWrite(at date: Date) { lastWriteAt = date }

    public func isWithinGrace(now: Date) -> Bool {
        guard let last = lastWriteAt else { return false }
        return now.timeIntervalSince(last) < Self.grace
    }

    /// 测试用
    public func reset() { lastWriteAt = nil }
}
