import CoreGraphics
import Foundation
import Testing
@testable import ToolboxKit

private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

@Test func freshStateIsIdle() {
    let s = SelectionState()
    #expect(s.phase == .idle)
    #expect(s.rect == nil)
    #expect(!s.exitRequested)
}

@Test func pressDragReleaseProducesSelection() {
    var s = SelectionState()
    s = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 100, y: 100)), bounds: screen)
    #expect(s.phase == .dragging)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 300, y: 400)), bounds: screen)
    #expect(s.rect == CGRect(x: 100, y: 100, width: 200, height: 300))
    s = SelectionReducer.reduce(s, .mouseUp, bounds: screen)
    #expect(s.phase == .hasSelection)
}

@Test func reverseDragStillYieldsPositiveRect() {
    var s = SelectionState()
    s = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 300, y: 400)), bounds: screen)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 100, y: 100)), bounds: screen)
    #expect(s.rect == CGRect(x: 100, y: 100, width: 200, height: 300))
}

@Test func dragIsClampedToScreen() {
    var s = SelectionState()
    s = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 900, y: 700)), bounds: screen)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 5000, y: 5000)), bounds: screen)
    #expect(s.rect?.maxX ?? 0 <= screen.maxX + 0.001)
    #expect(s.rect?.maxY ?? 0 <= screen.maxY + 0.001)
}

@Test func escapeClearsSelectionFirstAndOnlyThenExits() {
    // 两段式 Esc：有选区时先清选区，已经没选区了才退出截图（Snipaste 行为）
    var s = SelectionState()
    s = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 10, y: 10)), bounds: screen)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 50, y: 50)), bounds: screen)
    s = SelectionReducer.reduce(s, .mouseUp, bounds: screen)
    s = SelectionReducer.reduce(s, .escape, bounds: screen)
    #expect(s.rect == nil && s.phase == .idle && !s.exitRequested)
    s = SelectionReducer.reduce(s, .escape, bounds: screen)
    #expect(s.exitRequested)
}

@Test func escapeWhileDraggingCancelsSelectionNotTheWholeCapture() {
    var s = SelectionState()
    s = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 10, y: 10)), bounds: screen)
    s = SelectionReducer.reduce(s, .escape, bounds: screen)
    #expect(s.phase == .idle && s.rect == nil && !s.exitRequested)
}

@Test func nudgeMovesByOnePixelAndStaysInside() {
    var s = SelectionState()
    s = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 0, y: 0)), bounds: screen)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 100, y: 100)), bounds: screen)
    s = SelectionReducer.reduce(s, .mouseUp, bounds: screen)
    s = SelectionReducer.reduce(s, .nudge(dx: 1, dy: 1), bounds: screen)
    #expect(s.rect == CGRect(x: 1, y: 1, width: 100, height: 100))
    for _ in 0..<2000 { s = SelectionReducer.reduce(s, .nudge(dx: 1, dy: 1), bounds: screen) }
    #expect(s.rect?.maxX ?? 0 <= screen.maxX + 0.001)
    #expect(s.rect?.maxY ?? 0 <= screen.maxY + 0.001)
}

@Test func resizeNudgeChangesSizeNotOrigin() {
    var s = SelectionState()
    s = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 100, y: 100)), bounds: screen)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 200, y: 200)), bounds: screen)
    s = SelectionReducer.reduce(s, .mouseUp, bounds: screen)
    s.activeHandle = .bottomRight
    s = SelectionReducer.reduce(s, .resizeNudge(dx: 5, dy: 5), bounds: screen)
    #expect(s.rect?.origin == CGPoint(x: 100, y: 100))
    #expect(s.rect?.size == CGSize(width: 105, height: 105))
}

@Test func handleHitTestingCoversAllNineRegions() {
    let r = CGRect(x: 100, y: 100, width: 200, height: 200)
    let t: CGFloat = 6
    #expect(SelectionReducer.handle(at: CGPoint(x: 100, y: 100), in: r, tolerance: t) == .topLeft)
    #expect(SelectionReducer.handle(at: CGPoint(x: 300, y: 300), in: r, tolerance: t) == .bottomRight)
    #expect(SelectionReducer.handle(at: CGPoint(x: 200, y: 100), in: r, tolerance: t) == .top)
    #expect(SelectionReducer.handle(at: CGPoint(x: 100, y: 200), in: r, tolerance: t) == .left)
    #expect(SelectionReducer.handle(at: CGPoint(x: 200, y: 250), in: r, tolerance: t) == .inside)
    #expect(SelectionReducer.handle(at: CGPoint(x: 500, y: 500), in: r, tolerance: t) == .outside)
}

@Test func cornerBeatsEdgeWhenBothWithinTolerance() {
    // 角落里同时落在 top 和 left 的容差内，必须判成 topLeft，否则拖角会变成拖边
    let r = CGRect(x: 100, y: 100, width: 200, height: 200)
    #expect(SelectionReducer.handle(at: CGPoint(x: 102, y: 102), in: r, tolerance: 8) == .topLeft)
}

@Test func handleDragResizesFromTheOppositeCorner() {
    var s = SelectionState()
    s = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 100, y: 100)), bounds: screen)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 300, y: 300)), bounds: screen)
    s = SelectionReducer.reduce(s, .mouseUp, bounds: screen)
    // 抓住左上角往外拖：右下角必须钉住不动
    s = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 100, y: 100)), bounds: screen)
    #expect(s.activeHandle == .topLeft)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 60, y: 60)), bounds: screen)
    #expect(s.rect?.maxX == 300 && s.rect?.maxY == 300)
    #expect(s.rect?.minX == 60 && s.rect?.minY == 60)
}

@Test func clickingOutsideSelectionStartsAFreshRegion() {
    var s = SelectionState()
    s = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 100, y: 100)), bounds: screen)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 200, y: 200)), bounds: screen)
    s = SelectionReducer.reduce(s, .mouseUp, bounds: screen)
    s = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 500, y: 500)), bounds: screen)
    #expect(s.phase == .dragging)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 600, y: 620)), bounds: screen)
    #expect(s.rect == CGRect(x: 500, y: 500, width: 100, height: 120))
}

@Test func commitRequiresASelection() {
    #expect(SelectionState().canCommit == false)
    var s = SelectionState()
    s = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 1, y: 1)), bounds: screen)
    #expect(s.canCommit == false)          // 正在拖但还没成形
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 50, y: 50)), bounds: screen)
    s = SelectionReducer.reduce(s, .mouseUp, bounds: screen)
    #expect(s.canCommit == true)
}
