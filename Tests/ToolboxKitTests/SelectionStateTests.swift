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

@Test func selectWindowTakesWholeWindowAsSelection() {
    let win = CGRect(x: 120, y: 80, width: 600, height: 400)
    let s = SelectionReducer.reduce(SelectionState(), .selectWindow(win), bounds: screen)
    #expect(s.rect == win)
    #expect(s.phase == .hasSelection)
    #expect(s.canCommit)
}

@Test func selectWindowClipsToScreen() {
    let offscreen = CGRect(x: 900, y: 700, width: 400, height: 400)
    let s = SelectionReducer.reduce(SelectionState(), .selectWindow(offscreen), bounds: screen)
    #expect(s.rect?.maxX ?? 0 <= screen.maxX + 0.001)
    #expect(s.rect?.maxY ?? 0 <= screen.maxY + 0.001)
}

@Test func selectWindowIgnoresDegenerateRect() {
    let s = SelectionReducer.reduce(SelectionState(),
                                    .selectWindow(CGRect(x: 5, y: 5, width: 0, height: 0)),
                                    bounds: screen)
    #expect(s.rect == nil && s.phase == .idle)
}

@Test func dragSnapsWhenTargetsSupplied() {
    let t = SnapTargets(xs: [302], ys: [402])
    var s = SelectionReducer.reduce(SelectionState(), .mouseDown(CGPoint(x: 100, y: 100)),
                                   bounds: screen, snap: t)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 305, y: 405)),
                                bounds: screen, snap: t)
    #expect(s.rect?.maxX == 302)
    #expect(s.rect?.maxY == 402)
}

@Test func dragWithoutTargetsDoesNotSnap() {
    var s = SelectionReducer.reduce(SelectionState(), .mouseDown(CGPoint(x: 100, y: 100)),
                                   bounds: screen)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 305, y: 405)), bounds: screen)
    #expect(s.rect == CGRect(x: 100, y: 100, width: 205, height: 305))
}

@Test func keyboardNudgeIsNeverSnapped() {
    // 方向键是像素级微调，吸附会和它打架，所以 nudge 一律不吸
    let t = SnapTargets(xs: [100], ys: [100])
    var s = SelectionReducer.reduce(SelectionState(), .mouseDown(CGPoint(x: 104, y: 104)),
                                   bounds: screen, snap: t)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 204, y: 204)), bounds: screen, snap: t)
    s = SelectionReducer.reduce(s, .mouseUp, bounds: screen, snap: t)
    let before = s.rect
    s = SelectionReducer.reduce(s, .nudge(dx: 1, dy: 0), bounds: screen, snap: t)
    #expect(s.rect?.minX == (before?.minX ?? 0) + 1)
}

// MARK: 单击整窗 vs 拖动自由框

private let hoverWin = CGRect(x: 204, y: 143, width: 904, height: 728)

@Test func clickWithoutDragSelectsWholeWindow() {
    var s = SelectionReducer.reduce(SelectionState(),
                                    .mouseDown(CGPoint(x: 400, y: 300), hover: hoverWin),
                                    bounds: screen)
    // 按下瞬间就预览整窗，用户立刻能看到会框住哪个窗口
    #expect(s.rect == hoverWin)
    s = SelectionReducer.reduce(s, .mouseUp, bounds: screen)
    #expect(s.rect == hoverWin && s.phase == .hasSelection)
}

@Test func tinyDragStillCountsAsClick() {
    var s = SelectionReducer.reduce(SelectionState(),
                                    .mouseDown(CGPoint(x: 400, y: 300), hover: hoverWin),
                                    bounds: screen)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 402, y: 301)), bounds: screen)
    #expect(s.rect == hoverWin)          // 手抖不该把整窗变成怪异的 2pt 框
}

@Test func dragPastThresholdGivesFreeRectangleNotWindow() {
    // 这条就是修复动机：之前按下即整窗选中，用户没法从窗口内部起笔框局部
    var s = SelectionReducer.reduce(SelectionState(),
                                    .mouseDown(CGPoint(x: 400, y: 300), hover: hoverWin),
                                    bounds: screen)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 520, y: 430)), bounds: screen)
    #expect(s.rect == CGRect(x: 400, y: 300, width: 120, height: 130))
    #expect(s.rect != hoverWin)
    s = SelectionReducer.reduce(s, .mouseUp, bounds: screen)
    #expect(s.rect == CGRect(x: 400, y: 300, width: 120, height: 130))
}

@Test func dragWithoutHoverWindowBehavesAsBefore() {
    var s = SelectionReducer.reduce(SelectionState(),
                                    .mouseDown(CGPoint(x: 10, y: 10), hover: nil),
                                    bounds: screen)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 60, y: 60)), bounds: screen)
    #expect(s.rect == CGRect(x: 10, y: 10, width: 50, height: 50))
}

@Test func hoverPreviewIsDroppedOnSecondDragStart() {
    // 已有选区后再按下（抓把手/搬动）不该再引入 pendingWindow
    var s = SelectionReducer.reduce(SelectionState(),
                                    .mouseDown(CGPoint(x: 10, y: 10), hover: hoverWin),
                                    bounds: screen)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 200, y: 200)), bounds: screen)
    s = SelectionReducer.reduce(s, .mouseUp, bounds: screen)
    #expect(s.pendingWindow == nil)
    s = SelectionReducer.reduce(s, .mouseDown(CGPoint(x: 200, y: 200), hover: hoverWin),
                                bounds: screen)
    #expect(s.pendingWindow == nil)      // 非 idle 时的按下是搬动/缩放，不是整窗
}

@Test func snapAppliesToFreeDragButNotToWindowSelection() {
    // 整窗选中用的是窗口自己的边界，再吸一遍只会引入误差
    let t = SelectionSnapping.targets(windows: [hoverWin], screen: screen)
    var s = SelectionReducer.reduce(SelectionState(),
                                    .mouseDown(CGPoint(x: 400, y: 300), hover: hoverWin),
                                    bounds: screen, snap: t)
    #expect(s.rect == hoverWin)
    // 自由拖拽则应该吸到窗口边界上
    s = SelectionReducer.reduce(SelectionState(),
                                .mouseDown(CGPoint(x: 400, y: 300), hover: nil),
                                bounds: screen, snap: t)
    s = SelectionReducer.reduce(s, .mouseDragged(CGPoint(x: 208, y: 147)), bounds: screen, snap: t)
    #expect(s.rect?.minX == 204)
    #expect(s.rect?.minY == 143)
}
