import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import ToolboxKit

private let sel = CGRect(x: 100, y: 100, width: 400, height: 300)
private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

private func textAnn(_ s: String = "hello", at p: CGPoint = CGPoint(x: 150, y: 150),
                     size: CGFloat = 18) -> Annotation {
    Annotation(tool: .text, points: [p], color: .pureRed, lineWidth: 2, text: s, fontSize: size)
}
private func rectAnn(filled: Bool = false) -> Annotation {
    Annotation(tool: .rect, points: [CGPoint(x: 150, y: 150), CGPoint(x: 250, y: 210)],
               color: .pureRed, lineWidth: 4, filled: filled)
}

// MARK: 命中测试

@Test func textHitUsesRenderedBoxNotTheAnchor() {
    // boundingBox 只含锚点、面积为 0，用它的话文字永远点不中
    let a = textAnn("hello world")
    #expect(a.boundingBox.width == 0)
    #expect(a.textRect.width > 60)
    let mid = CGPoint(x: a.textRect.midX, y: a.textRect.midY)
    #expect(AnnotationHitTest.hits(a, at: mid))
    #expect(AnnotationHitTest.hits(a, at: CGPoint(x: 152, y: 152)))
    #expect(AnnotationHitTest.hits(a, at: CGPoint(x: a.textRect.maxX - 2, y: 160)))
    #expect(!AnnotationHitTest.hits(a, at: CGPoint(x: 400, y: 400)))
}

@Test func hollowRectIsOnlyHitOnTheBorder() {
    // 空心矩形若整块可点中，框内空白就永远点不到别的东西、也没法在里头画
    let a = rectAnn(filled: false)
    #expect(AnnotationHitTest.hits(a, at: CGPoint(x: 150, y: 180)))     // 左边框
    #expect(AnnotationHitTest.hits(a, at: CGPoint(x: 200, y: 150)))     // 上边框
    #expect(!AnnotationHitTest.hits(a, at: CGPoint(x: 200, y: 180)))    // 正中间是空的
    #expect(AnnotationHitTest.hits(rectAnn(filled: true), at: CGPoint(x: 200, y: 180)))
}

@Test func penAndArrowHitNearTheirLines() {
    let pen = Annotation(tool: .pen,
                         points: [CGPoint(x: 150, y: 150), CGPoint(x: 250, y: 250)],
                         color: .pureRed, lineWidth: 4)
    #expect(AnnotationHitTest.hits(pen, at: CGPoint(x: 200, y: 200)))
    #expect(!AnnotationHitTest.hits(pen, at: CGPoint(x: 250, y: 150)))   // 离折线远
    let arrow = Annotation(tool: .arrow, points: [CGPoint(x: 300, y: 150), CGPoint(x: 400, y: 150)],
                           color: .pureRed, lineWidth: 4)
    #expect(AnnotationHitTest.hits(arrow, at: CGPoint(x: 350, y: 152)))
    #expect(!AnnotationHitTest.hits(arrow, at: CGPoint(x: 350, y: 220)))
}

@Test func topmostWinsWhenShapesOverlap() {
    // 后画的在上面：从下往上找会让被盖住的图形抢走点击
    let bottom = Annotation(tool: .rect, points: [CGPoint(x: 150, y: 150), CGPoint(x: 350, y: 300)],
                            color: .pureBlue, lineWidth: 4, filled: true)
    let top = Annotation(tool: .rect, points: [CGPoint(x: 200, y: 180), CGPoint(x: 260, y: 220)],
                         color: .pureRed, lineWidth: 4, filled: true)
    let id = AnnotationHitTest.topmost(at: CGPoint(x: 230, y: 200), in: [bottom, top])
    #expect(id == top.id)
    #expect(AnnotationHitTest.topmost(at: CGPoint(x: 400, y: 400), in: [bottom, top]) == nil)
}

@Test func incompleteShapesAreNotHitTargets() {
    let half = Annotation(tool: .pen, points: [CGPoint(x: 150, y: 150)],
                          color: .pureRed, lineWidth: 4)
    #expect(AnnotationHitTest.topmost(at: CGPoint(x: 150, y: 150), in: [half]) == nil)
}

/// 走真实交互路径播种一个图形（直接塞 annotations 会让撤销栈和内容不一致，
/// 测出来的 canUndo 是假的）
private func seeded(_ a: Annotation) -> AnnotationState {
    var st = AnnotationState()
    st.tool = a.tool
    st.down(at: a.points[0], in: sel)
    if a.tool == .text {
        st.up()
        st.commitText(a.text ?? "", fontSize: a.fontSize, editing: nil)
    } else {
        if a.points.count > 1 { st.drag(to: a.points[1], in: sel) }
        st.up()
    }
    return st
}

// MARK: 移动

@Test func movingAnAnnotationFollowsCursorWithoutAccumulating() {
    var st = seeded(rectAnn(filled: true))
    let base = st.annotations[0].points
    st.beginMove(id: st.annotations[0].id, at: CGPoint(x: 200, y: 180))
    // 显式 CGFloat：#expect 在 CGFloat 与整数字面量混算时会误判 false（项目里记过）
    for step in stride(from: CGFloat(5), through: CGFloat(40), by: CGFloat(5)) {
        st.dragMove(to: CGPoint(x: 200 + step, y: 180), in: sel)
        #expect(st.annotations[0].points[0].x == base[0].x + step)
    }
    st.endMove()
    #expect(st.annotations[0].points[0].x == base[0].x + CGFloat(40))
    #expect(st.movingID == nil)
}

@Test func wholeShapeStaysInsideWhenDraggedFar() {
    var st = seeded(rectAnn(filled: true))
    st.beginMove(id: st.annotations[0].id, at: CGPoint(x: 200, y: 180))
    for step in stride(from: 5.0, through: 40.0, by: 5) {
        st.dragMove(to: CGPoint(x: 200 + step, y: 180), in: sel)
    }
    st.endMove()
    st.undo()
    #expect(st.annotations[0].points[0].x == 150)     // 一步就回到移动前
    st.undo()
    #expect(st.annotations.isEmpty)                    // 再一步回到"什么都没有"
    #expect(st.canUndo == false)
}

@Test func tapWithoutMovingIsReportedNotCommitted() {
    var st = seeded(textAnn())
    let stepsBefore = st.canUndo
    st.beginMove(id: st.annotations[0].id, at: CGPoint(x: 160, y: 160))
    st.dragMove(to: CGPoint(x: 161, y: 160), in: sel)      // 1pt，在阈值内
    st.endMove()
    #expect(st.tappedID == st.annotations[0].id)
    #expect(st.canUndo == stepsBefore)                      // 没真的动过 → 不压一步
    #expect(st.annotations[0].points[0] == CGPoint(x: 150, y: 150))   // 临时偏移已还原
}

@Test func movingIsClampedToTheSelection() {
    var st = seeded(rectAnn(filled: true))
    st.beginMove(id: st.annotations[0].id, at: CGPoint(x: 200, y: 180))
    st.dragMove(to: CGPoint(x: 5000, y: 5000), in: sel)
    st.endMove()
    let bb = st.annotations[0].boundingBox
    #expect(bb.maxX <= sel.maxX + 0.001)
    #expect(bb.maxY <= sel.maxY + 0.001)
    #expect(bb.width == 100 && bb.height == 60)     // 尺寸不变，只是被贴到右下角
}

// MARK: reducer 路由

@Test func clickingAnExistingShapeMovesItInsteadOfTheSelection() {
    var s = SelectionState()
    s.rect = sel
    s.phase = .hasSelection
    s.annotation.annotations = [rectAnn(filled: true)]
    let id = s.annotation.annotations[0].id
    let down = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 200, y: 180)),
                                       bounds: screen, hit: id)
    #expect(down.annotation.movingID == id)
    #expect(down.rect == sel)                              // 选区一动不动
    let moved = SelectionReducer.reduce(down, .mouseDragged(CGPoint(x: 240, y: 200)),
                                        bounds: screen)
    #expect(moved.annotation.annotations[0].points[0].x == 190)
    #expect(moved.rect == sel)
    let up = SelectionReducer.reduce(moved, .mouseUp, bounds: screen)
    #expect(up.annotation.movingID == nil)
    #expect(up.annotation.canUndo)
}

@Test func textToolOnExistingTextEditsInsteadOfStacking() {
    var s = SelectionState()
    s.rect = sel
    s.phase = .hasSelection
    s.annotation.tool = .text
    s.annotation.annotations = [textAnn("旧字", at: CGPoint(x: 150, y: 150))]
    let id = s.annotation.annotations[0].id
    var out = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 160, y: 160)),
                                      bounds: screen, hit: id)
    out = SelectionReducer.reduce(out, .mouseUp, bounds: screen)
    #expect(out.annotation.tappedID == id)                 // 视图据此重开编辑器
    #expect(out.annotation.annotations.count == 1)         // 没有凭空多一块
    out = SelectionReducer.reduce(out, .commitText("新字", fontSize: 18, editing: id), bounds: screen)
    #expect(out.annotation.annotations.count == 1)
    #expect(out.annotation.annotations[0].text == "新字")
}

@Test func emptyingAnExistingTextDeletesThatBlock() {
    var s = SelectionState()
    s.rect = sel
    s.phase = .hasSelection
    s.annotation = seeded(textAnn("要删的"))
    s.annotation.tool = .text
    let id = s.annotation.annotations[0].id
    var out = SelectionReducer.reduce(s, .commitText("   ", fontSize: 18, editing: id),
                                      bounds: screen)
    #expect(out.annotation.annotations.isEmpty)
    out = SelectionReducer.reduce(out, .undoAnnotation, bounds: screen)
    #expect(out.annotation.annotations.count == 1)         // 删错了能撤销回来
}

@Test func textToolOnEmptySpaceStillStartsANewBlock() {
    var s = SelectionState()
    s.rect = sel
    s.phase = .hasSelection
    s.annotation.tool = .text
    s.annotation.annotations = [textAnn("已有一块", at: CGPoint(x: 150, y: 150))]
    let out = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 400, y: 350)),
                                      bounds: screen, hit: nil)
    #expect(out.annotation.movingID == nil)
    #expect(out.annotation.draft != nil)
    #expect(out.annotation.textAnchor == CGPoint(x: 400, y: 350))
}
