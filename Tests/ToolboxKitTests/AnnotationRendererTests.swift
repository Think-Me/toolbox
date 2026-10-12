import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import ToolboxKit

/// 白底画布 + 把像素读回来断言。
/// 肉眼看预览永远看不出"导出时线宽减半"这类问题，只能采样。
private func canvas(_ size: Int, fill: [CGFloat] = [1, 1, 1, 1]) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(colorSpace: cs, components: fill)!)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    // 顶原点（y 向下），与遮罩视图的 flipped 坐标一致
    ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)
    return ctx
}

private func hex(_ image: CGImage, _ x: Int, _ y: Int) -> String? {
    Magnifier.hexColor(of: image, pixelX: x, pixelY: y)
}

private let white = "#FFFFFF"

/// 横向线段在某列上占了几行 —— 这就是"线宽是否随 scale 放大"的量法
private func inkedRows(_ image: CGImage, atColumn x: Int) -> Int {
    (0..<image.height).filter { hex(image, x, $0) != white }.count
}
private func inkedColumns(_ image: CGImage, atRow y: Int) -> Int {
    (0..<image.width).filter { hex(image, $0, y) != white }.count
}

// MARK: 矩形

@Test func filledRectPaintsInsideAndNotOutside() {
    let ctx = canvas(200)
    let a = Annotation(tool: .rect, points: [CGPoint(x: 50, y: 50), CGPoint(x: 120, y: 120)],
                       color: .pureRed, lineWidth: 2, filled: true)
    AnnotationRenderer.render([a], in: ctx, scale: 1, origin: .zero, mosaicSource: nil)
    let img = ctx.makeImage()!
    #expect(hex(img, 85, 85) == "#FF0000")
    #expect(hex(img, 10, 10) == white)
    #expect(hex(img, 150, 150) == white)
}

@Test func hollowRectPaintsBorderOnly() {
    let ctx = canvas(200)
    let a = Annotation(tool: .rect, points: [CGPoint(x: 50, y: 50), CGPoint(x: 120, y: 120)],
                       color: .pureRed, lineWidth: 2, filled: false)
    AnnotationRenderer.render([a], in: ctx, scale: 1, origin: .zero, mosaicSource: nil)
    let img = ctx.makeImage()!
    #expect(hex(img, 85, 85) == white)      // 中间是空的
    #expect(hex(img, 85, 50) == "#FF0000")  // 上边框
}

@Test func rectDefaultsToHollow() {
    // 默认不填充：截图标注不该一上来就盖住底下的内容
    let ctx = canvas(200)
    let a = Annotation(tool: .rect, points: [CGPoint(x: 50, y: 50), CGPoint(x: 120, y: 120)],
                       color: .pureRed, lineWidth: 2)
    AnnotationRenderer.render([a], in: ctx, scale: 1, origin: .zero, mosaicSource: nil)
    #expect(hex(ctx.makeImage()!, 85, 85) == white)
}

// MARK: 线宽/字号必须随 scale 放大（本文件存在的意义）

@Test func lineWidthScalesWithDeviceScale() {
    let line = Annotation(tool: .pen, points: [CGPoint(x: 10, y: 100), CGPoint(x: 190, y: 100)],
                          color: .pureBlue, lineWidth: 4)
    let ctx1 = canvas(200)
    AnnotationRenderer.render([line], in: ctx1, scale: 1, origin: .zero, mosaicSource: nil)
    let thin = inkedRows(ctx1.makeImage()!, atColumn: 100)

    let ctx2 = canvas(400)
    AnnotationRenderer.render([line], in: ctx2, scale: 2, origin: .zero, mosaicSource: nil)
    let thick = inkedRows(ctx2.makeImage()!, atColumn: 200)

    #expect(thin >= 3 && thin <= 6)
    #expect(thick >= 7 && thick <= 12)
    #expect(thick > thin)
}

@Test func originOffsetShiftsDrawing() {
    // 导出时 ctx 的原点是选区左上角，必须把坐标减去 origin
    let ctx = canvas(200)
    let a = Annotation(tool: .rect, points: [CGPoint(x: 150, y: 150), CGPoint(x: 190, y: 190)],
                       color: .pureGreen, lineWidth: 2, filled: true)
    AnnotationRenderer.render([a], in: ctx, scale: 1,
                              origin: CGPoint(x: 150, y: 150), mosaicSource: nil)
    let img = ctx.makeImage()!
    #expect(hex(img, 10, 10) == AnnotationColor.pureGreen.hexString)
    #expect(hex(img, 150, 150) == white)
}

// MARK: 箭头

@Test func arrowPaintsShaftAndHead() {
    let ctx = canvas(200)
    let a = Annotation(tool: .arrow, points: [CGPoint(x: 20, y: 100), CGPoint(x: 150, y: 100)],
                       color: .pureRed, lineWidth: 3)
    AnnotationRenderer.render([a], in: ctx, scale: 1, origin: .zero, mosaicSource: nil)
    let img = ctx.makeImage()!
    #expect(hex(img, 100, 100) == "#FF0000")
    #expect(hex(img, 145, 100) == "#FF0000")
    #expect(hex(img, 10, 10) == white)
    #expect(hex(img, 170, 100) == white)   // 不该画到尖点之外
}

@Test func degenerateArrowDoesNotBreakOutput() {
    let ctx = canvas(100)
    let a = Annotation(tool: .arrow, points: [CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 50)],
                       color: .pureRed, lineWidth: 3)
    AnnotationRenderer.render([a], in: ctx, scale: 1, origin: .zero, mosaicSource: nil)
    #expect(ctx.makeImage() != nil)
}

// MARK: 画笔

@Test func penCoversFirstAndLastPoint() {
    let ctx = canvas(200)
    let a = Annotation(tool: .pen,
                       points: [CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 90), CGPoint(x: 150, y: 160)],
                       color: .pureBlack, lineWidth: 6)
    AnnotationRenderer.render([a], in: ctx, scale: 1, origin: .zero, mosaicSource: nil)
    let img = ctx.makeImage()!
    #expect(hex(img, 20, 30) == "#000000")
    #expect(hex(img, 150, 160) == "#000000")
}

@Test func singlePointPenIsIgnored() {
    let ctx = canvas(100)
    let a = Annotation(tool: .pen, points: [CGPoint(x: 50, y: 50)],
                       color: .pureRed, lineWidth: 4)
    AnnotationRenderer.render([a], in: ctx, scale: 1, origin: .zero, mosaicSource: nil)
    #expect(inkedColumns(ctx.makeImage()!, atRow: 50) == 0)
}

// MARK: 文字

@Test func textInkHeightScales() {
    func inked(_ scale: CGFloat, _ size: Int) -> Int {
        let ctx = canvas(size)
        let a = Annotation(tool: .text, points: [CGPoint(x: 10, y: 10)],
                           color: .pureBlack, lineWidth: 2, text: "Hg", fontSize: 20)
        AnnotationRenderer.render([a], in: ctx, scale: scale, origin: .zero, mosaicSource: nil)
        guard let img = ctx.makeImage() else { return 0 }
        var rows = 0
        for y in 0..<size where (0..<size).contains(where: { hex(img, $0, y) != white }) { rows += 1 }
        return rows
    }
    let at1 = inked(1, 120)
    let at2 = inked(2, 240)
    #expect(at1 > 5)
    #expect(at2 > at1 * 2 - 4)
}

@Test func textIsNotVerticallyMirrored() {
    // 在 y 向下的 CGContext 里直接画字符串的经典结果就是上下颠倒。
    // "T" 上宽下窄，镜像后变成上窄下宽 —— 用行宽差判定。
    let ctx = canvas(120)
    let a = Annotation(tool: .text, points: [CGPoint(x: 10, y: 10)],
                       color: .pureBlack, lineWidth: 2, text: "T", fontSize: 60)
    AnnotationRenderer.render([a], in: ctx, scale: 1, origin: .zero, mosaicSource: nil)
    guard let img = ctx.makeImage() else { Issue.record("出图失败"); return }
    let inked = (0..<120).filter { y in (0..<120).contains { hex(img, $0, y) != white } }
    #expect(inked.count > 10)
    let top = inked[5], bottom = inked[inked.count - 6]
    #expect(inkedColumns(img, atRow: top) > inkedColumns(img, atRow: bottom))
}

@Test func whitespaceTextIsNotDrawn() {
    let ctx = canvas(100)
    let a = Annotation(tool: .text, points: [CGPoint(x: 5, y: 5)],
                       color: .pureBlack, lineWidth: 2, text: "   ")
    AnnotationRenderer.render([a], in: ctx, scale: 1, origin: .zero, mosaicSource: nil)
    #expect(inkedColumns(ctx.makeImage()!, atRow: 20) == 0)
}

@Test func emptyListLeavesCanvasUntouched() {
    let ctx = canvas(100)
    AnnotationRenderer.render([], in: ctx, scale: 1, origin: .zero, mosaicSource: nil)
    #expect(hex(ctx.makeImage()!, 50, 50) == white)
}

@Test func incompleteAnnotationIsNotDrawn() {
    // 正在拖的第一帧只有 1 个点，不能当成成品画出来（预览靠单独的路径）
    let ctx = canvas(200)
    let a = Annotation(tool: .rect, points: [CGPoint(x: 50, y: 50)],
                       color: .pureRed, lineWidth: 2)
    AnnotationRenderer.render([a], in: ctx, scale: 1, origin: .zero, mosaicSource: nil)
    #expect(inkedColumns(ctx.makeImage()!, atRow: 50) == 0)
}

// MARK: 马赛克

private func noisyImage(_ size: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in 0..<size {
        for x in 0..<size {
            ctx.setFillColor(CGColor(colorSpace: cs, components:
                [CGFloat((x * 7 + y * 13) % 256) / 255,
                 CGFloat((x * 31 + y * 5) % 256) / 255,
                 CGFloat((x * 3 + y * 17) % 256) / 255, 1])!)
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return ctx.makeImage()!
}

@Test func mosaicSourceMapsPointsToPixels() {
    let src = MosaicSource(image: noisyImage(600), scale: 2)
    #expect(src.pixelRect(of: CGRect(x: 100, y: 200, width: 50, height: 60))
            == CGRect(x: 200, y: 400, width: 100, height: 120))
}

@Test func mosaicSourceClampsOutOfBounds() {
    let src = MosaicSource(image: noisyImage(600), scale: 2)
    let r = src.pixelRect(of: CGRect(x: -50, y: -50, width: 1000, height: 1000))
    #expect(r.minX >= 0 && r.minY >= 0)
    #expect(r.maxX <= 600 && r.maxY <= 600)
}

@Test func mosaicReducesColorVarietyInsideItsRegion() {
    let frozen = noisyImage(400)
    let src = MosaicSource(image: frozen, scale: 1)
    let ctx = canvas(400, fill: [0, 0, 0, 1])
    ctx.draw(frozen, in: CGRect(x: 0, y: 0, width: 400, height: 400))
    let a = Annotation(tool: .mosaic, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 300)],
                       color: .pureBlack, lineWidth: 2)
    AnnotationRenderer.render([a], in: ctx, scale: 1, origin: .zero, mosaicSource: src)
    guard let img = ctx.makeImage() else { Issue.record("出图失败"); return }

    func distinct(_ xs: Range<Int>, _ ys: Range<Int>) -> Int {
        var s = Set<String>()
        for y in stride(from: ys.lowerBound, to: ys.upperBound, by: 3) {
            for x in stride(from: xs.lowerBound, to: xs.upperBound, by: 3) {
                if let h = hex(img, x, y) { s.insert(h) }
            }
        }
        return s.count
    }
    let inside = distinct(110..<290, 110..<290)
    let outside = distinct(10..<90, 10..<90)
    #expect(outside > 20)              // 噪声图未处理区几乎全是不同颜色
    #expect(inside < outside / 2)      // 200pt 见方只剩 ~17x17 格
}

@Test func mosaicIsBlockyNotSmooth() {
    // 一个格子内部应当是纯色；若逐格尺寸不对就会看到渐变/错位
    let frozen = noisyImage(400)
    let src = MosaicSource(image: frozen, scale: 1)
    let ctx = canvas(400, fill: [0, 0, 0, 1])
    ctx.draw(frozen, in: CGRect(x: 0, y: 0, width: 400, height: 400))
    let a = Annotation(tool: .mosaic, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 300)],
                       color: .pureBlack, lineWidth: 2)
    AnnotationRenderer.render([a], in: ctx, scale: 1, origin: .zero, mosaicSource: src)
    guard let img = ctx.makeImage() else { Issue.record("出图失败"); return }
    let cell = Int(AnnotationPalette.mosaicCellPoints)
    // 取第 1 格（112..<124）的内部，避开 1px 边界与格子接缝
    let x0 = 100 + cell, y0 = 100 + cell
    let anchor = hex(img, x0 + 1, y0 + 1)
    #expect(anchor != white)
    var same = true
    for dy in 0..<(cell - 3) {
        for dx in 0..<(cell - 3) where hex(img, x0 + 1 + dx, y0 + 1 + dy) != anchor { same = false }
    }
    #expect(same)
}

@Test func mosaicWithoutSourceFallsBackToVisibleBlock() {
    // 拿不到冻结帧时也要画出可见的东西，
    // 而不是静默什么都不画 —— 用户会以为"马赛克工具坏了"
    let ctx = canvas(200)
    let a = Annotation(tool: .mosaic, points: [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 150)],
                       color: .pureBlack, lineWidth: 2)
    AnnotationRenderer.render([a], in: ctx, scale: 1, origin: .zero, mosaicSource: nil)
    #expect(inkedColumns(ctx.makeImage()!, atRow: 100) > 0)
}
