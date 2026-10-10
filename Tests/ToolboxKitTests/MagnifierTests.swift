import CoreGraphics
import Foundation
import Testing
@testable import ToolboxKit

private func makeImage(_ w: Int, _ h: Int, fill: [CGFloat]) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(colorSpace: cs, components: fill)!)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

@Test func sourceRectCentersOnCursorPixel() {
    let r = Magnifier.sourceRect(cursorInScreenPoints: CGPoint(x: 100, y: 100),
                                 scale: 2, imageSize: CGSize(width: 3024, height: 1964))
    // 光标像素 (200,200)，取 15×15 居中 → 左上角 = 200 - 7
    #expect(r == CGRect(x: 193, y: 193, width: 15, height: 15))
}

@Test func sourceRectClampsAtTopLeftWithoutNegativeOrigin() {
    let r = Magnifier.sourceRect(cursorInScreenPoints: .zero, scale: 2,
                                 imageSize: CGSize(width: 3024, height: 1964))
    #expect(r.origin == .zero)
    #expect(r.width == 15 && r.height == 15)
}

@Test func sourceRectClampsAtBottomRightInsideImage() {
    let size = CGSize(width: 3024, height: 1964)
    let r = Magnifier.sourceRect(cursorInScreenPoints: CGPoint(x: 1512, y: 982),
                                 scale: 2, imageSize: size)
    #expect(r.maxX <= CGFloat(size.width))
    #expect(r.maxY <= CGFloat(size.height))
    #expect(r.width == 15 && r.height == 15)
}

@Test func sourceRectKeepsFullSizeOnTinyImages() {
    // 图像比放大镜还小（极端缩放/坏数据）时不许算出负原点
    let r = Magnifier.sourceRect(cursorInScreenPoints: CGPoint(x: 2, y: 2), scale: 1,
                                 imageSize: CGSize(width: 6, height: 6))
    #expect(r.minX >= 0 && r.minY >= 0)
    #expect(r.width <= 6 && r.height <= 6)
}

@Test func hexColorReadsBackExactRGB() {
    let img = makeImage(4, 4, fill: [1, 0, 0, 1])
    #expect(Magnifier.hexColor(of: img, pixelX: 2, pixelY: 2) == "#FF0000")
    let green = makeImage(4, 4, fill: [0, 1, 0, 1])
    #expect(Magnifier.hexColor(of: green, pixelX: 0, pixelY: 0) == "#00FF00")
    let mixed = makeImage(4, 4, fill: [0.2, 0.4, 0.6, 1])
    #expect(Magnifier.hexColor(of: mixed, pixelX: 1, pixelY: 1) == "#336699")
}

@Test func hexColorRejectsOutOfBounds() {
    let img = makeImage(4, 4, fill: [0, 0, 0, 1])
    #expect(Magnifier.hexColor(of: img, pixelX: 4, pixelY: 0) == nil)
    #expect(Magnifier.hexColor(of: img, pixelX: 0, pixelY: 4) == nil)
    #expect(Magnifier.hexColor(of: img, pixelX: -1, pixelY: 0) == nil)
}

@Test func magnifierFrameFlipsToOtherSideNearEdges() {
    let container = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 120, height: 140)
    // 光标在中间：放大镜放右下
    let mid = Magnifier.frame(cursor: CGPoint(x: 500, y: 400), container: container, size: size)
    #expect(mid.minX >= 500 && mid.minY >= 400)
    // 贴右下角：翻到左上，且不出容器
    let corner = Magnifier.frame(cursor: CGPoint(x: 990, y: 790), container: container, size: size)
    #expect(corner.maxX <= container.maxX + 0.001)
    #expect(corner.maxY <= container.maxY + 0.001)
    #expect(corner.maxX <= 990)
}

@Test func magnifierFrameAlwaysStaysInsideContainer() {
    let container = CGRect(x: 0, y: 0, width: 400, height: 300)
    let size = CGSize(width: 120, height: 140)
    for x in stride(from: CGFloat(0), through: 400, by: 20) {
        for y in stride(from: CGFloat(0), through: 300, by: 20) {
            let f = Magnifier.frame(cursor: CGPoint(x: x, y: y), container: container, size: size)
            #expect(f.minX >= -0.001 && f.minY >= -0.001)
            #expect(f.maxX <= container.maxX + 0.001)
            #expect(f.maxY <= container.maxY + 0.001)
        }
    }
}

@Test func crosshairIsAtTheCenterCell() {
    // 15×15 源像素画到 120×120，每格 8pt，中心格是第 7 格（0-based 6）
    let cell = Magnifier.outputSize / CGFloat(Magnifier.sourcePixels)
    #expect(cell == 8)
    #expect(Magnifier.crosshairOffset == CGFloat(Magnifier.sourcePixels / 2) * cell)
}

@Test func sizeLabelUsesPointsNotPixels() {
    // 显示给用户看的必须是 points，否则 Retina 下用户会觉得"框了 2 倍大"
    #expect(Magnifier.sizeLabel(pointsSize: CGSize(width: 400, height: 300)) == "400 × 300")
}
