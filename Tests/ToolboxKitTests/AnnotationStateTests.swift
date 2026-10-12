import CoreGraphics
import Foundation
import Testing
@testable import ToolboxKit

private let sel = CGRect(x: 100, y: 100, width: 400, height: 300)

private func selected(_ tool: AnnotationTool?) -> SelectionState {
    var s = SelectionState()
    s.rect = sel
    s.phase = .hasSelection
    s.annotation.tool = tool
    return s
}

private func drag(_ s: SelectionState, from: CGPoint, to: CGPoint,
                  bounds: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)) -> SelectionState {
    var out = SelectionReducer.reduce(s, .annotationDown(from), bounds: bounds)
    out = SelectionReducer.reduce(out, .annotationDragged(to), bounds: bounds)
    return SelectionReducer.reduce(out, .annotationUp, bounds: bounds)
}

// MARK: 工具非空时拖拽不改选区

@Test func activeToolMeansDragDoesNotMoveSelection() {
    let s = selected(.rect)
    let before = s.rect!
    let dragged = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 200, y: 200)), bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    // 活动工具下，鼠标事件不该再走选区逻辑：选区必须一动不动
    #expect(dragged.rect == before)
    #expect(dragged.phase == .hasSelection)
}

@Test func noToolKeepsOldSelectionBehavior() {
    // 零回归：工具为 nil 时，拖内部仍然是整体移动选区
    let s = selected(nil)
    var out = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 300, y: 250)), bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    out = SelectionReducer.reduce(out, .mouseDragged(CGPoint(x: 340, y: 290)), bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    #expect(out.rect?.origin.x == 140)
    #expect(out.annotation.annotations.isEmpty)
}

// MARK: 抬笔生成图形

@Test func penUpProducesOneAnnotation() {
    let out = drag(selected(.rect), from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 220))
    #expect(out.annotation.annotations.count == 1)
    let a = out.annotation.annotations[0]
    #expect(a.tool == .rect)
    #expect(a.boundingBox == CGRect(x: 150, y: 150, width: 100, height: 70))
    #expect(out.annotation.draft == nil)
}

@Test func draftIsNotVisibleUntilPenUp() {
    var s = SelectionReducer.reduce(selected(.pen), .annotationDown(CGPoint(x: 150, y: 150)), bounds: sel)
    s = SelectionReducer.reduce(s, .annotationDragged(CGPoint(x: 200, y: 200)), bounds: sel)
    #expect(s.annotation.annotations.isEmpty)     // 还在笔上，不该进列表
    #expect(s.annotation.draft != nil)
    #expect(s.annotation.draft?.points.count == 2)
}

@Test func rectArrowMosaicCompleteWithTwoPoints() {
    for tool in [AnnotationTool.rect, .arrow, .mosaic] {
        let out = drag(selected(tool), from: CGPoint(x: 120, y: 120), to: CGPoint(x: 180, y: 160))
        #expect(out.annotation.annotations.count == 1, "工具 \(tool) 两点就该成")
    }
}

@Test func penKeepsManyPointsAndIsSimplified() {
    var s = selected(.pen)
    s = SelectionReducer.reduce(s, .annotationDown(CGPoint(x: 150, y: 150)), bounds: sel)
    for i in 0..<300 {
        let p = CGPoint(x: 150 + CGFloat(i), y: 150)
        s = SelectionReducer.reduce(s, .annotationDragged(p), bounds: sel)
    }
    s = SelectionReducer.reduce(s, .annotationUp, bounds: sel)
    #expect(s.annotation.draft == nil)
    let a = s.annotation.annotations[0]
    #expect(a.points.count >= 2)
    #expect(a.points.count < 300)                 // 抽稀生效
    #expect(a.points.first == CGPoint(x: 150, y: 150))
    #expect(a.boundingBox.maxX == 449)
}

@Test func singleClickWithPenProducesNothing() {
    // 手抖点一下不该留下可撤销的一步，否则撤销栈里全是空步
    var s = selected(.pen)
    s = SelectionReducer.reduce(s, .annotationDown(CGPoint(x: 150, y: 150)), bounds: sel)
    s = SelectionReducer.reduce(s, .annotationUp, bounds: sel)
    #expect(s.annotation.annotations.isEmpty)
    #expect(s.annotation.canUndo == false)
}

@Test func subPointJitterProducesNothing() {
    // 位移不足 1pt 的"拖拽"在 down 处就被过滤掉，等于没画。
    // 这条和 singleClickWithPenProducesNothing 是同一件事的两面：
    // 否则用户每次手抖都会在撤销栈里留一步看不见的内容
    var s = selected(.pen)
    s = SelectionReducer.reduce(s, .annotationDown(CGPoint(x: 150, y: 150)), bounds: sel)
    s = SelectionReducer.reduce(s, .annotationDragged(CGPoint(x: 150.2, y: 150.1)), bounds: sel)
    s = SelectionReducer.reduce(s, .annotationUp, bounds: sel)
    #expect(s.annotation.annotations.isEmpty)
    #expect(s.annotation.canUndo == false)
}

@Test func justOverOnePointProducesAStroke() {
    var s = selected(.pen)
    s = SelectionReducer.reduce(s, .annotationDown(CGPoint(x: 150, y: 150)), bounds: sel)
    s = SelectionReducer.reduce(s, .annotationDragged(CGPoint(x: 152, y: 150)), bounds: sel)
    s = SelectionReducer.reduce(s, .annotationUp, bounds: sel)
    #expect(s.annotation.annotations.count == 1)
}

// MARK: 点必须钳在选区内

@Test func pointsAreClampedToSelection() {
    let out = drag(selected(.rect), from: CGPoint(x: 110, y: 110), to: CGPoint(x: 900, y: 900))
    #expect(out.annotation.annotations[0].boundingBox.maxX <= sel.maxX)
    #expect(out.annotation.annotations[0].boundingBox.maxY <= sel.maxY)
}

// MARK: 撤销

@Test func undoRemovesLastAnnotation() {
    var s = selected(.pen)
    s = drag2(s, from: CGPoint(x: 120, y: 120), to: CGPoint(x: 160, y: 140))
    s = drag2(s, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 240, y: 240))
    #expect(s.annotation.annotations.count == 2)
    s = SelectionReducer.reduce(s, .undoAnnotation, bounds: sel)
    #expect(s.annotation.annotations.count == 1)
    #expect(s.annotation.annotations[0].boundingBox.minX == 120)
    s = SelectionReducer.reduce(s, .redoAnnotation, bounds: sel)
    #expect(s.annotation.annotations.count == 2)
}

@Test func undoWithNoAnnotationsIsSafe() {
    let s = SelectionReducer.reduce(selected(.rect), .undoAnnotation, bounds: sel)
    #expect(s.annotation.annotations.isEmpty)
    #expect(s.annotation.canUndo == false)
    #expect(s.rect == sel)                 // 撤销不该顺手把选区也弄没
}

@Test func clearIsUndoable() {
    var s = selected(.rect)
    s = drag2(s, from: CGPoint(x: 120, y: 120), to: CGPoint(x: 160, y: 140))
    s = SelectionReducer.reduce(s, .clearAnnotations, bounds: sel)
    #expect(s.annotation.annotations.isEmpty)
    s = SelectionReducer.reduce(s, .undoAnnotation, bounds: sel)
    #expect(s.annotation.annotations.count == 1)
}

@Test func clearWhenAlreadyEmptyAddsNoUndoStep() {
    let s = SelectionReducer.reduce(selected(.rect), .clearAnnotations, bounds: sel)
    #expect(s.annotation.canUndo == false)
}

@Test func switchingToolsDiscardsTheDraft() {
    var s = SelectionReducer.reduce(selected(.pen), .annotationDown(CGPoint(x: 150, y: 150)), bounds: sel)
    #expect(s.annotation.draft != nil)
    s = SelectionReducer.reduce(s, .toolChanged(.arrow), bounds: sel)
    #expect(s.annotation.draft == nil)
    #expect(s.annotation.tool == .arrow)
}

@Test func annotationsSurviveSelectionResize() {
    // 标注是钉在**冻结帧**上的，不是钉在选区框上：改选区不该丢标注
    var s = drag(selected(.rect), from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 220))
    s.rect = CGRect(x: 100, y: 100, width: 200, height: 200)
    #expect(s.annotation.annotations.count == 1)
    #expect(s.annotation.annotations[0].boundingBox.minX == 150)
}

@Test func textNeedsCommittedStringNotJustAClick() {
    // 任务 7 的接缝：光点一下不产生标注，否则编辑器一取消就留个空框
    var s = selected(.text)
    s = SelectionReducer.reduce(s, .annotationDown(CGPoint(x: 150, y: 150)), bounds: sel)
    s = SelectionReducer.reduce(s, .annotationUp, bounds: sel)
    #expect(s.annotation.annotations.isEmpty)
    s = SelectionReducer.reduce(s, .commitText("你好", fontSize: 18), bounds: sel)
    #expect(s.annotation.annotations.count == 1)
    #expect(s.annotation.annotations[0].text == "你好")
    #expect(s.annotation.annotations[0].fontSize == 18)
}

@Test func committedTextIsUndoable() {
    var s = selected(.text)
    s = SelectionReducer.reduce(s, .annotationDown(CGPoint(x: 150, y: 150)), bounds: sel)
    s = SelectionReducer.reduce(s, .annotationUp, bounds: sel)
    s = SelectionReducer.reduce(s, .commitText("hi", fontSize: 18), bounds: sel)
    s = SelectionReducer.reduce(s, .undoAnnotation, bounds: sel)
    #expect(s.annotation.annotations.isEmpty)
}

@Test func annotationWithoutSelectionIsIgnored() {
    // 还没有选区就画（理论上工具条此时不可点，但状态机不能信 UI）
    var s = SelectionState()
    s.annotation.tool = .rect
    s = SelectionReducer.reduce(s, .annotationDown(CGPoint(x: 10, y: 10)), bounds: sel)
    s = SelectionReducer.reduce(s, .annotationDragged(CGPoint(x: 50, y: 50)), bounds: sel)
    s = SelectionReducer.reduce(s, .annotationUp, bounds: sel)
    #expect(s.annotation.annotations.isEmpty)
    #expect(s.rect == nil)
}

private func drag2(_ s: SelectionState, from: CGPoint, to: CGPoint) -> SelectionState {
    drag(s, from: from, to: to)
}

@Test func fontSizeChoiceAppliesToNextStrokeAndIsUndoable() {
    var s = selected(.text)
    s = SelectionReducer.reduce(s, .annotationFontSize(26), bounds: sel)
    #expect(s.annotation.fontSize == 26)
    s = SelectionReducer.reduce(s, .annotationDown(CGPoint(x: 150, y: 150)), bounds: sel)
    s = SelectionReducer.reduce(s, .annotationUp, bounds: sel)
    s = SelectionReducer.reduce(s, .commitText("大字", fontSize: s.annotation.fontSize), bounds: sel)
    #expect(s.annotation.annotations.last?.fontSize == 26)
    s = SelectionReducer.reduce(s, .undoAnnotation, bounds: sel)
    #expect(s.annotation.annotations.isEmpty)
}
