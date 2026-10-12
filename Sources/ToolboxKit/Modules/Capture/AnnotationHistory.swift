import Foundation

/// 标注的撤销栈：**整份快照**，不是每个工具自己实现逆操作。
///
/// 为什么不用命令对象：那要求 5 种工具各自写对 undo/redo（改色、删字、移动马赛克……），
/// 任何一个写错就是"撤销后画面错乱"，而且这类 bug 很难稳定复现。
/// 快照的代价只是内存（上限 50 份 × 几十条小结构体，可忽略），
/// 换来所有工具共用一套撤销逻辑、不可能不一致。
public struct AnnotationHistory: Equatable, Sendable {
    /// 超过就丢最旧的一步（保留"什么都没有"这个基态，见 trim 说明）
    public static let limit = 50

    private var states: [[Annotation]]
    private var index: Int

    public init() {
        states = [[]]        // 基态：空画布。撤销到底就是它。
        index = 0
    }

    public var current: [Annotation] { states[index] }
    public var canUndo: Bool { index > 0 }
    public var canRedo: Bool { index < states.count - 1 }
    public var stateCount: Int { states.count }

    /// 提交一份新状态。与当前相同则跳过——抬笔但没画不该产生一步可撤销的操作。
    public mutating func commit(_ annotations: [Annotation]) {
        guard annotations != states[index] else { return }
        // 撤销后再画，就丢弃 redo 分支：否则"撤销 → 画新的 → 重做"
        // 会拿到一份早该作废的旧图
        if index < states.count - 1 {
            states.removeSubrange((index + 1)...)
        }
        states.append(annotations)
        index = states.count - 1
        trimIfNeeded()
    }

    @discardableResult
    public mutating func undo() -> [Annotation]? {
        guard canUndo else { return nil }
        index -= 1
        return states[index]
    }

    @discardableResult
    public mutating func redo() -> [Annotation]? {
        guard canRedo else { return nil }
        index += 1
        return states[index]
    }

    /// 超上限时删掉 index 1（最旧的**真实步骤**），而不是 index 0。
    /// 基态"空画布"必须永远留着，否则撤销到底会停在一个有内容的状态，
    /// 用户就没法把整张图撤干净了。
    private mutating func trimIfNeeded() {
        while states.count > Self.limit, states.count > 1 {
            states.remove(at: 1)
            index -= 1
        }
        index = Swift.max(0, Swift.min(index, states.count - 1))
    }
}
