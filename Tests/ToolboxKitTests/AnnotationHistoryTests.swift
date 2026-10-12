import CoreGraphics
import Foundation
import Testing
@testable import ToolboxKit

private func ann(x: CGFloat, tool: AnnotationTool = .rect) -> Annotation {
    Annotation(tool: tool, points: [CGPoint(x: x, y: 0), CGPoint(x: x + 10, y: 10)],
               color: .pureRed, lineWidth: 2)
}

@Test func freshHistoryHasNothingToUndo() {
    var h = AnnotationHistory()
    #expect(h.canUndo == false)
    #expect(h.canRedo == false)
    #expect(h.current.isEmpty)
    h.commit([])
    #expect(h.canUndo == false)          // 空→空 不算一步
}

@Test func commitThenUndoRedo() {
    var h = AnnotationHistory()
    let a = ann(x: 1)
    let b = ann(x: 2)
    h.commit([a])
    h.commit([a, b])
    #expect(h.current.count == 2)
    #expect(h.canUndo)
    #expect(h.undo()?.count == 1)
    #expect(h.current.count == 1)
    #expect(h.canRedo)
    #expect(h.redo()?.count == 2)
    #expect(h.current.count == 2)
}

@Test func identicalCommitIsSkipped() {
    // 抬笔但没画（或重复提交同一份）不该产生一步可撤销的操作
    var h = AnnotationHistory()
    let a = ann(x: 1)
    h.commit([a])
    let stepsBefore = h.undo()
    h.commit([a])
    #expect(h.canRedo == false)          // 第二次 commit 没增加 redo 分支
    #expect(h.current.count == 1)
    _ = stepsBefore
}

@Test func commitAfterUndoDiscardsRedoBranch() {
    // 不丢弃的话，用户"撤销后画新的再重做"会拿到一份早该作废的旧图
    var h = AnnotationHistory()
    let a = ann(x: 1), b = ann(x: 2)
    h.commit([a])
    h.commit([a, b])
    _ = h.undo()
    #expect(h.canRedo)
    h.commit([ann(x: 9)])
    #expect(h.canRedo == false)
    #expect(h.current.count == 1)
    #expect(h.current[0].points[0].x == 9)
}

@Test func undoPastTheStartIsSafe() {
    var h = AnnotationHistory()
    h.commit([ann(x: 1)])
    #expect(h.undo()?.isEmpty == true)
    #expect(h.undo() == nil)             // 到顶了返回 nil，不崩、不越界
    #expect(h.canUndo == false)
    #expect(h.current.isEmpty)
}

@Test func redoPastTheEndIsSafe() {
    var h = AnnotationHistory()
    #expect(h.redo() == nil)
    h.commit([ann(x: 1)])
    #expect(h.redo() == nil)
}

@Test func limitDropsOldestStatesWithoutBreakingIndices() {
    var h = AnnotationHistory()
    var list: [Annotation] = []
    for i in 0..<(AnnotationHistory.limit + 20) {
        list.append(ann(x: CGFloat(i)))
        h.commit(list)
    }
    #expect(h.stateCount == AnnotationHistory.limit)
    // 丢最旧的之后，undo 到底应该停在"现存最旧那一步"而不是崩或跳空
    var steps = 0
    while h.undo() != nil { steps += 1 }
    #expect(steps == AnnotationHistory.limit - 1)
    #expect(h.canUndo == false)
    #expect(h.current.isEmpty)           // 最旧那一步是"什么都没有"
}

@Test func clearIsJustAnEmptyCommit() {
    var h = AnnotationHistory()
    h.commit([ann(x: 1)])
    h.commit([])
    #expect(h.current.isEmpty)
    #expect(h.undo()?.count == 1)        // 清空本身可撤销，这很重要
}

@Test func currentIsAlwaysInSyncWithUndoResult() {
    var h = AnnotationHistory()
    let a = ann(x: 1), b = ann(x: 2), c = ann(x: 3)
    h.commit([a]); h.commit([a, b]); h.commit([a, b, c])
    _ = h.undo()
    #expect(h.current == [a, b])
    _ = h.undo()
    #expect(h.current == [a])
    _ = h.redo()
    #expect(h.current == [a, b])
}

@Test func toolSpecificShapesAreAllUndoable() {
    // 五种工具共用同一套撤销：这条测试就是为了让"某工具自己实现撤销"的写法无处藏身
    var h = AnnotationHistory()
    var list: [Annotation] = []
    for tool in AnnotationTool.allCases {
        let p = tool == .pen
            ? [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5), CGPoint(x: 9, y: 1)]
            : [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 20)]
        list.append(Annotation(tool: tool, points: p, color: .pureBlue,
                               lineWidth: 3, text: tool == .text ? "hi" : nil))
        h.commit(list)
    }
    #expect(h.current.count == 5)
    for expected in stride(from: 4, through: 0, by: -1) {
        #expect(h.undo()?.count == expected)
    }
}
