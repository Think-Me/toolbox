import CoreGraphics
import Foundation
import Testing
@testable import ToolboxKit

@Test func contentSizeScalesWithZoom() {
    var m = PinZoomModel(intrinsic: CGSize(width: 200, height: 100))
    #expect(m.contentSize == CGSize(width: 200, height: 100))
    m.zoom = 2
    #expect(m.contentSize == CGSize(width: 400, height: 200))
}

@Test func scrollZoomIsMultiplicativeNotAdditive() {
    // 累加会让小步长几乎看不出变化、大步长又一下子飞掉；
    // 连续两次相同增量必须等于一次双倍增量（等比）
    var a = PinZoomModel(intrinsic: .init(width: 100, height: 100))
    var b = PinZoomModel(intrinsic: .init(width: 100, height: 100))
    a.apply(delta: 10, magnifySign: 1)
    a.apply(delta: 10, magnifySign: 1)
    b.apply(delta: 20, magnifySign: 1)
    #expect(abs(a.zoom - b.zoom) < 0.0001)
    #expect(a.zoom > 1.4 && a.zoom < 1.6)     // 10 个单位约 1.5×，不是 1+0.2
}

@Test func zoomIsClampedAtBothEnds() {
    var m = PinZoomModel(intrinsic: .init(width: 100, height: 100), minZoom: 0.2, maxZoom: 8)
    for _ in 0..<200 { m.apply(delta: 50, magnifySign: 1) }
    #expect(m.zoom == 8)
    for _ in 0..<200 { m.apply(delta: -50, magnifySign: 1) }
    #expect(m.zoom == 0.2)
}

@Test func magnifySignReversesDirection() {
    var up = PinZoomModel(intrinsic: .init(width: 100, height: 100))
    var down = PinZoomModel(intrinsic: .init(width: 100, height: 100))
    up.apply(delta: 20, magnifySign: 1)
    down.apply(delta: 20, magnifySign: -1)
    #expect(up.zoom > 1)
    #expect(down.zoom < 1)
    #expect(abs(up.zoom * down.zoom - 1) < 0.001)   // 同一增量方向相反应互为倒数
}

@Test func magnificationGestureSharesTheSameZoomState() {
    // 捏合与滚轮必须动同一个 zoom，否则两套手势会互相"看不见"对方的结果
    var m = PinZoomModel(intrinsic: .init(width: 100, height: 100))
    m.apply(delta: 20, magnifySign: 1)
    let afterScroll = m.zoom
    m.applyMagnificationDelta(0.5)
    #expect(m.zoom > afterScroll)
    m.zoom = 1
    #expect(abs(m.zoom - 1) < 0.0001)
}

@Test func magnificationDeltaIsRelativeAndClamped() {
    var m = PinZoomModel(intrinsic: .init(width: 100, height: 100), minZoom: 0.2, maxZoom: 8)
    m.applyMagnificationDelta(100)
    #expect(m.zoom == 8)
    m.applyMagnificationDelta(-100)
    #expect(m.zoom == 0.2)
}

@Test func nearestNeighborKicksInAtExtremeZoom() {
    var m = PinZoomModel(intrinsic: .init(width: 100, height: 100))
    m.zoom = 1
    #expect(!m.usesNearestNeighbor)
    m.zoom = 1.5
    #expect(!m.usesNearestNeighbor)
    m.zoom = 2
    #expect(m.usesNearestNeighbor)      // 放大看清单像素
    m.zoom = 0.5
    #expect(m.usesNearestNeighbor)      // 缩到极小也要锐利，不要糊成一团
    m.zoom = 0.8
    #expect(!m.usesNearestNeighbor)
}

@Test func resetReturnsToOne() {
    var m = PinZoomModel(intrinsic: .init(width: 100, height: 100))
    m.apply(delta: 40, magnifySign: 1)
    #expect(m.zoom != 1)
    m.reset()
    #expect(m.zoom == 1)
}

@Test func stepZoomMultipliesByFixedFactor() {
    var m = PinZoomModel(intrinsic: .init(width: 100, height: 100))
    m.step(by: 1)
    #expect(abs(m.zoom - PinZoomModel.stepFactor) < 0.0001)
    m.step(by: -1)
    #expect(abs(m.zoom - 1) < 0.0001)
}

@Test func opacityIsClampedAndNeverInvisible() {
    var m = PinZoomModel(intrinsic: .init(width: 100, height: 100))
    #expect(m.opacity == 1)
    m.adjustOpacity(by: -10)
    #expect(m.opacity == PinZoomModel.minOpacity)
    m.adjustOpacity(by: 100)
    #expect(m.opacity == 1)
    // 低于这个值贴图就"看不见但还在占位"，比不显示更糟
    #expect(PinZoomModel.minOpacity >= 0.2)
}

@Test func rotationSwapsIntrinsicSize() {
    var m = PinZoomModel(intrinsic: .init(width: 200, height: 100))
    m.rotate90()
    #expect(m.intrinsic == CGSize(width: 100, height: 200))
    #expect(m.rotationDegrees == 90)
    m.rotate90()
    #expect(m.intrinsic == CGSize(width: 200, height: 100))
    #expect(m.rotationDegrees == 180)
    for _ in 0..<2 { m.rotate90() }
    #expect(m.rotationDegrees == 0)
}

@Test func zeroIntrinsicDoesNotProduceNaN() {
    var m = PinZoomModel(intrinsic: .zero)
    m.apply(delta: 10, magnifySign: 1)
    #expect(m.zoom.isFinite)
    #expect(m.contentSize.width.isFinite)
}
