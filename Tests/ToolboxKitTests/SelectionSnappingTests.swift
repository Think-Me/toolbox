import CoreGraphics
import Foundation
import Testing
@testable import ToolboxKit

// 坐标系约定：全部是遮罩视图的 flipped 坐标（左上原点，y 向下）

@Test func targetsIncludeScreenEdgesAndWindowEdges() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let t = SelectionSnapping.targets(
        windows: [CGRect(x: 100, y: 120, width: 200, height: 80)], screen: screen)
    #expect(t.xs.contains(0) && t.xs.contains(1000))
    #expect(t.ys.contains(0) && t.ys.contains(800))
    #expect(t.xs.contains(100) && t.xs.contains(300))
    #expect(t.ys.contains(120) && t.ys.contains(200))
}

@Test func targetsDeduplicateSharedEdges() {
    // 两个窗口左边界相同，吸附线只应出现一次（否则计数类断言会骗人）
    let t = SelectionSnapping.targets(
        windows: [CGRect(x: 50, y: 10, width: 40, height: 20),
                  CGRect(x: 50, y: 60, width: 40, height: 20)],
        screen: CGRect(x: 0, y: 0, width: 500, height: 500))
    #expect(t.xs.filter { $0 == 50 }.count == 1)
}

@Test func emptyWindowListStillSnapsToScreenEdges() {
    let t = SelectionSnapping.targets(windows: [], screen: CGRect(x: 0, y: 0, width: 800, height: 600))
    #expect(Set(t.xs) == Set<CGFloat>([0, 800]))
    #expect(Set(t.ys) == Set<CGFloat>([0, 600]))
}

@Test func snapWithinToleranceMovesEdgeExactlyOntoTarget() {
    let t = SnapTargets(xs: [200], ys: [])
    let r = CGRect(x: 204, y: 50, width: 100, height: 40)
    let s = SelectionSnapping.snap(r, to: t, tolerance: 6)
    #expect(s.rect.minX == 200)
    #expect(s.snappedEdges == [.left])
    // 左边界动了、右边界没动 → 宽度随之变
    #expect(s.rect.width == 104)
}

@Test func snapOutsideToleranceLeavesRectAlone() {
    let t = SnapTargets(xs: [200], ys: [])
    let r = CGRect(x: 210, y: 50, width: 100, height: 40)
    let s = SelectionSnapping.snap(r, to: t, tolerance: 6)
    #expect(s.rect == r)
    #expect(s.snappedEdges.isEmpty)
}

@Test func toleranceBoundaryIsInclusive() {
    // 恰好等于容差必须吸附：写成开区间会造成"差一点点就是吸不上"的手感问题
    let t = SnapTargets(xs: [100], ys: [100])
    let exact = SelectionSnapping.snap(CGRect(x: 106, y: 94, width: 50, height: 50),
                                       to: t, tolerance: 6)
    #expect(exact.snappedEdges.contains(.left))
    #expect(exact.snappedEdges.contains(.top))
}

@Test func snapAllFourEdgesOfFullScreenishRect() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let t = SelectionSnapping.targets(windows: [], screen: screen)
    let s = SelectionSnapping.snap(CGRect(x: 4, y: 6, width: 990, height: 792),
                                   to: t, tolerance: 6)
    #expect(s.rect == screen)
    #expect(s.snappedEdges == [.left, .right, .top, .bottom])
}

@Test func opposingEdgesSnappingPastEachOtherNeverInverts() {
    // 左右都吸到线上但两线距离为负 → 必须钳成最小 1pt，
    // 否则选区会翻向（width<0），后续裁剪/贴图全部拿到畸形矩形
    let t = SnapTargets(xs: [300, 100], ys: [])
    let s = SelectionSnapping.snap(CGRect(x: 104, y: 10, width: 200, height: 20),
                                   to: t, tolerance: 6)
    #expect(s.rect.width >= 1)
    #expect(s.rect.minX <= s.rect.maxX)
}

@Test func topmostWindowRespectsFrontToBackOrder() {
    let back = CGRect(x: 0, y: 0, width: 800, height: 600)
    let front = CGRect(x: 100, y: 100, width: 200, height: 200)
    // 输入顺序 = 从前到后
    #expect(SelectionSnapping.topmostWindow(containing: CGPoint(x: 150, y: 150),
                                            in: [front, back]) == front)
    #expect(SelectionSnapping.topmostWindow(containing: CGPoint(x: 500, y: 500),
                                            in: [front, back]) == back)
    #expect(SelectionSnapping.topmostWindow(containing: CGPoint(x: 900, y: 900),
                                            in: [front, back]) == nil)
}

@Test func topmostWindowIgnoresZeroAreaCandidates() {
    let degenerate = CGRect(x: 10, y: 10, width: 0, height: 0)
    #expect(SelectionSnapping.topmostWindow(containing: CGPoint(x: 10, y: 10),
                                            in: [degenerate]) == nil)
}

@Test func snapIsIdempotent() {
    // 已经吸上的矩形再算一次不该继续漂移
    let t = SnapTargets(xs: [200, 500], ys: [100, 400])
    let once = SelectionSnapping.snap(CGRect(x: 203, y: 97, width: 300, height: 305),
                                      to: t, tolerance: 6)
    let twice = SelectionSnapping.snap(once.rect, to: t, tolerance: 6)
    #expect(twice.rect == once.rect)
}

@Test func targetsIgnoreWindowsFullyOffscreen() {
    let t = SelectionSnapping.targets(
        windows: [CGRect(x: -5000, y: -5000, width: 100, height: 100)],
        screen: CGRect(x: 0, y: 0, width: 800, height: 600))
    #expect(t.xs == [0, 800])
    #expect(t.ys == [0, 600])
}
