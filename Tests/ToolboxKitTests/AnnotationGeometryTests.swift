import CoreGraphics
import Foundation
import Testing
@testable import ToolboxKit

// MARK: 矩形归一化

@Test func rectFromDragIsNormalizedInAllFourDirections() {
    let expected = CGRect(x: 100, y: 100, width: 200, height: 300)
    let cases: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 400)),
        (CGPoint(x: 300, y: 400), CGPoint(x: 100, y: 100)),
        (CGPoint(x: 100, y: 400), CGPoint(x: 300, y: 100)),
        (CGPoint(x: 300, y: 100), CGPoint(x: 100, y: 400)),
    ]
    for (a, b) in cases {
        #expect(AnnotationGeometry.rect(from: a, to: b) == expected)
    }
}

@Test func rectOfIdenticalPointsIsZeroSized() {
    let r = AnnotationGeometry.rect(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5))
    #expect(r == CGRect(x: 5, y: 5, width: 0, height: 0))
}

// MARK: 箭头头部

@Test func arrowHeadPointsBackFromTheTip() {
    // 水平向右的箭头：头部两翼应在终点左侧
    let head = AnnotationGeometry.arrowHead(from: .zero, to: CGPoint(x: 100, y: 50),
                                            width: 12)
    #expect(head.count == 3)
    let tip = head[0]
    #expect(tip == CGPoint(x: 100, y: 50))
    #expect(head[1].x < tip.x && head[2].x < tip.x)
    // 两翼中点必须落在线段轴线上（不是"在尖点上"——那才是写错的断言）
    let mid = CGPoint(x: (head[1].x + head[2].x) / 2, y: (head[1].y + head[2].y) / 2)
    let axis = CGVector(dx: 100, dy: 50)
    let toMid = CGVector(dx: mid.x - 0, dy: mid.y - 0)
    let cross = axis.dx * toMid.dy - axis.dy * toMid.dx
    #expect(abs(cross) < 0.01)
    #expect(mid.x < tip.x)               // 中点在尖点之后（往起点方向）
}

@Test func arrowHeadFollowsDirection() {
    let right = AnnotationGeometry.arrowHead(from: .zero, to: CGPoint(x: 100, y: 0), width: 10)
    let up = AnnotationGeometry.arrowHead(from: .zero, to: CGPoint(x: 0, y: -100), width: 10)
    // 向右时两翼 x 小于尖；向上时两翼 y 大于尖
    #expect(right[1].x < 100 && right[2].x < 100)
    #expect(up[1].y > -100 && up[2].y > -100)
}

@Test func arrowHeadOnDegenerateLineHasNoNaN() {
    let head = AnnotationGeometry.arrowHead(from: CGPoint(x: 7, y: 7),
                                            to: CGPoint(x: 7, y: 7), width: 10)
    #expect(head.count == 3)
    #expect(head.allSatisfy { $0.x.isFinite && $0.y.isFinite })
}

@Test func arrowHeadSizeScalesWithLineWidth() {
    let thin = AnnotationGeometry.arrowHead(from: .zero, to: CGPoint(x: 100, y: 0), width: 2)
    let thick = AnnotationGeometry.arrowHead(from: .zero, to: CGPoint(x: 100, y: 0), width: 10)
    let spanThin = abs(thin[1].y - thin[2].y)
    let spanThick = abs(thick[1].y - thick[2].y)
    #expect(spanThick > spanThin)
}

// MARK: 画笔抽稀

@Test func simplifyDropsRedundantCollinearPoints() {
    // 触摸板慢慢拖一条水平线会产生上千个几乎同 y 的点
    let dense = (0..<1000).map { CGPoint(x: CGFloat($0) * 0.3, y: 50) }
    let out = AnnotationGeometry.simplify(dense, tolerance: 3)
    #expect(out.count < dense.count / 5)
    #expect(out.first == dense.first)
    #expect(out.last == dense.last)          // 端点必须保留，否则线会缩短
    #expect(out.allSatisfy { $0.y == 50 })
}

@Test func simplifyKeepsCorners() {
    let path: [CGPoint] = [(0, 0), (100, 0), (100, 100)].map { CGPoint(x: $0.0, y: $0.1) }
    let out = AnnotationGeometry.simplify(path, tolerance: 3)
    #expect(out.count == 3)
}

@Test func simplifyHandlesSmallInputs() {
    #expect(AnnotationGeometry.simplify([], tolerance: 3).isEmpty)
    #expect(AnnotationGeometry.simplify([.zero], tolerance: 3) == [.zero])
    let two = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
    #expect(AnnotationGeometry.simplify(two, tolerance: 3) == two)
}

@Test func simplifyNeverReordersPoints() {
    let path = (0..<50).map { CGPoint(x: CGFloat($0), y: CGFloat($0 % 7) * 5) }
    let out = AnnotationGeometry.simplify(path, tolerance: 2)
    let xs = out.map(\.x)
    #expect(xs == xs.sorted())
}

@Test func simplifyPreservesDirectionReversal() {
    // 来回画的线：中间那个折返点必须留，否则线会被"抄近路"
    let path: [CGPoint] = stride(from: 0.0, through: 30, by: 1).map { CGPoint(x: $0, y: 0) }
        + stride(from: 29.0, through: 0.0, by: -1).map { CGPoint(x: $0, y: 0) }
    let out = AnnotationGeometry.simplify(path, tolerance: 2)
    #expect(out.last?.x == 0)
    #expect((out.map(\.x).max() ?? 0) >= 29)
    #expect(out.count >= 3)
}

// MARK: 外接矩形

@Test func boundingBoxOfPointsHandlesEmptyAndSingle() {
    #expect(AnnotationGeometry.boundingBox(of: []) == .zero)
    #expect(AnnotationGeometry.boundingBox(of: [CGPoint(x: 3, y: 4)])
            == CGRect(x: 3, y: 4, width: 0, height: 0))
    #expect(AnnotationGeometry.boundingBox(of: [CGPoint(x: 10, y: 20), CGPoint(x: -5, y: 3)])
            == CGRect(x: -5, y: 3, width: 15, height: 17))
}

@Test func strokeToolsNeedTwoPointsButTextNeedsOne() {
    #expect(AnnotationTool.pen.minimumPointCount == 2)
    #expect(AnnotationTool.text.minimumPointCount == 1)
    #expect(AnnotationTool.mosaic.minimumPointCount == 2)
}
