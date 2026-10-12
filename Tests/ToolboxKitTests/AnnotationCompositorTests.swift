import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import ToolboxKit

private func hex(_ image: CGImage, _ x: Int, _ y: Int) -> String? {
    Magnifier.hexColor(of: image, pixelX: x, pixelY: y)
}

/// 顶上有红块的图：CGImage 的 row 0 在最上，所以要在 y-up 上下文里画到顶部
private func markedImage(_ size: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 0, 0, 1])!)
    ctx.fill(CGRect(x: 0, y: size - 50, width: 50, height: 50))
    return ctx.makeImage()!
}

private func noisyImage(_ size: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in 0..<size {
        for x in 0..<size {
            ctx.setFillColor(CGColor(colorSpace: cs, components:
                [CGFloat((x * 7 + y * 13) % 256) / 255,
                 CGFloat((x * 31 + y * 5) % 255) / 255,
                 CGFloat((x * 3 + y * 17) % 256) / 255, 1])!)
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return ctx.makeImage()!
}

private func blueRect(from: CGPoint, to: CGPoint) -> Annotation {
    Annotation(tool: .rect, points: [from, to], color: .pureBlue, lineWidth: 2, filled: true)
}

// MARK: 零回归

@Test func noAnnotationsIsByteIdenticalToPlainCrop() {
    let frozen = markedImage(400)
    let crop = ImageCodec.crop(frozen, pixelRect: CGRect(x: 100, y: 100, width: 200, height: 200))!
    let out = AnnotationCompositor.compose(frozen: frozen,
                                           pixelRect: CGRect(x: 100, y: 100, width: 200, height: 200),
                                           annotations: [], scale: 1,
                                           selectionOrigin: CGPoint(x: 100, y: 100))!
    // 逐字节相同：不画标注时绝不能因为"多走了一次位图重绘"而改变输出
    #expect(ImageCodec.png(out) == ImageCodec.png(crop))
}

@Test func onlyIncompleteAnnotationsAlsoShortCircuit() {
    let frozen = markedImage(400)
    let rect = CGRect(x: 0, y: 0, width: 400, height: 400)
    let half = Annotation(tool: .rect, points: [CGPoint(x: 1, y: 1)],
                          color: .pureBlue, lineWidth: 2)
    let out = AnnotationCompositor.compose(frozen: frozen, pixelRect: rect,
                                           annotations: [half], scale: 1, selectionOrigin: .zero)!
    #expect(ImageCodec.png(out) == ImageCodec.png(ImageCodec.crop(frozen, pixelRect: rect)!))
}

// MARK: 尺寸与方向

@Test func outputSizeMatchesCropPixelSize() {
    let frozen = markedImage(800)
    let out = AnnotationCompositor.compose(
        frozen: frozen, pixelRect: CGRect(x: 200, y: 200, width: 400, height: 300),
        annotations: [blueRect(from: CGPoint(x: 120, y: 120), to: CGPoint(x: 140, y: 140))],
        scale: 2, selectionOrigin: CGPoint(x: 100, y: 100))!
    #expect(out.width == 400 && out.height == 300)   // 不被降采样
}

@Test func baseImageIsNotMirrored() {
    // 红块在源图**顶部**；合成后还应在输出顶部。
    // 在 y-向下的上下文里直接 draw 图像就会镜像 —— 这条测试就是钉住它
    let frozen = markedImage(400)
    let out = AnnotationCompositor.compose(
        frozen: frozen, pixelRect: CGRect(x: 0, y: 0, width: 400, height: 400),
        annotations: [blueRect(from: CGPoint(x: 300, y: 300), to: CGPoint(x: 380, y: 380))],
        scale: 1, selectionOrigin: .zero)!
    #expect(hex(out, 10, 10) == "#FF0000")
    #expect(hex(out, 10, 390) == "#FFFFFF")
    #expect(hex(out, 340, 340) == "#0000FF")
}

// MARK: 选区原点（最容易错的一行）

@Test func selectionOffsetIsSubtracted() {
    // 选区在屏幕 (100,100)pt，scale=2 → 像素 (200,200)。
    // 标注画在 (110,110)pt，即相对选区左上角 10pt → 输出像素 (20,20)。
    let frozen = markedImage(800)
    let out = AnnotationCompositor.compose(
        frozen: frozen, pixelRect: CGRect(x: 200, y: 200, width: 400, height: 400),
        annotations: [blueRect(from: CGPoint(x: 110, y: 110), to: CGPoint(x: 130, y: 130))],
        scale: 2, selectionOrigin: CGPoint(x: 100, y: 100))!
    #expect(hex(out, 25, 25) == "#0000FF")
    #expect(hex(out, 215, 215) != "#0000FF")   // 不减原点就会跑到这里
}

@Test func retinaScaleDoublesAnnotationSize() {
    func blueSpan(_ scale: CGFloat) -> Int {
        let frozen = markedImage(800)
        let px = Int(200 * scale)
        let out = AnnotationCompositor.compose(
            frozen: frozen, pixelRect: CGRect(x: 0, y: 0, width: px, height: px),
            annotations: [blueRect(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 60, y: 90))],
            scale: scale, selectionOrigin: .zero)!
        // 取矩形纵向中点，避免踩边界：50pt 在 scale=2 时是第 100 行
        let row = Int(70 * scale)
        return (0..<out.width).filter { hex(out, $0, row) == "#0000FF" }.count
    }
    #expect(blueSpan(1) == 50)
    #expect(blueSpan(2) == 100)
}

// MARK: 越界

@Test func fullyOutOfBoundsPixelRectReturnsNil() {
    let frozen = markedImage(200)
    #expect(AnnotationCompositor.compose(frozen: frozen,
                                         pixelRect: CGRect(x: 500, y: 500, width: 100, height: 100),
                                         annotations: [], scale: 1,
                                         selectionOrigin: CGPoint(x: 500, y: 500)) == nil)
}

@Test func annotationsOutsideTheSelectionDoNotThrow() {
    let frozen = markedImage(400)
    let out = AnnotationCompositor.compose(
        frozen: frozen, pixelRect: CGRect(x: 0, y: 0, width: 400, height: 400),
        annotations: [blueRect(from: CGPoint(x: -50, y: -50), to: CGPoint(x: 50, y: 50))],
        scale: 1, selectionOrigin: .zero)
    #expect(out != nil)
}

// MARK: 马赛克的坐标映射

@Test func mosaicUsesFrozenFrameCoordinates() {
    // MosaicSource 若误用**裁剪后**的图，格子颜色会整体错位；
    // 这里把输出的一个格子和源图同一位置算出的格子颜色对上。
    let frozen = noisyImage(800)
    let scale: CGFloat = 2
    let selectionOrigin = CGPoint(x: 100, y: 100)
    let mosaic = Annotation(tool: .mosaic,
                            points: [CGPoint(x: 110, y: 110), CGPoint(x: 190, y: 190)],
                            color: .pureBlack, lineWidth: 2)
    let out = AnnotationCompositor.compose(
        frozen: frozen, pixelRect: CGRect(x: 200, y: 200, width: 400, height: 400),
        annotations: [mosaic], scale: scale, selectionOrigin: selectionOrigin)!

    let cell = AnnotationPalette.mosaicCellPoints
    let grid = MosaicSource(image: frozen, scale: scale)
        .grid(for: CGRect(x: 110, y: 110, width: 80, height: 80), cellPoints: cell)!
    let expected = grid.color(col: 1, row: 1)!.hexString

    // 第 1 格覆盖 point [122,134) → 相对选区 (22,34)pt → 输出像素 (44,68)
    let x = Int((110 + cell - selectionOrigin.x) * scale) + 2
    let y = Int((110 + cell - selectionOrigin.y) * scale) + 2
    #expect(x == 46 && y == 46)
    #expect(hex(out, x, y) == expected)
}

// MARK: 导出分支决定

@Test func exportWithoutAnnotationsMatchesLegacyPath() {
    let frozen = markedImage(400)
    let px = CGRect(x: 100, y: 100, width: 200, height: 150)
    let legacy = ImageCodec.png(ImageCodec.crop(frozen, pixelRect: px)!)
    let out = AnnotationCompositor.exportPNG(frozen: frozen, pixelRect: px, annotations: [],
                                             scale: 1, selectionOrigin: CGPoint(x: 100, y: 100))!
    #expect(out.data == legacy)
    #expect(out.pixelSize == CGSize(width: 200, height: 150))
}

@Test func exportWithAnnotationsChangesBytesButNotSize() {
    let frozen = markedImage(400)
    let px = CGRect(x: 100, y: 100, width: 200, height: 150)
    let plain = AnnotationCompositor.exportPNG(frozen: frozen, pixelRect: px, annotations: [],
                                               scale: 1, selectionOrigin: CGPoint(x: 100, y: 100))!
    let a = blueRect(from: CGPoint(x: 110, y: 110), to: CGPoint(x: 160, y: 140))
    let out = AnnotationCompositor.exportPNG(frozen: frozen, pixelRect: px, annotations: [a],
                                             scale: 1, selectionOrigin: CGPoint(x: 100, y: 100))!
    #expect(out.data != plain.data)
    #expect(out.pixelSize == plain.pixelSize)   // 标注绝不能改变输出尺寸
}

@Test func exportKeepsRetinaPixelSize() {
    // Retina 上带标注的输出必须是**原生像素**尺寸，
    // 一旦被当成 point 处理就会小一半
    let frozen = markedImage(800)
    let px = CGRect(x: 200, y: 200, width: 400, height: 300)
    let a = blueRect(from: CGPoint(x: 110, y: 110), to: CGPoint(x: 140, y: 130))
    let out = AnnotationCompositor.exportPNG(frozen: frozen, pixelRect: px, annotations: [a],
                                             scale: 2, selectionOrigin: CGPoint(x: 100, y: 100))!
    #expect(out.pixelSize == CGSize(width: 400, height: 300))
}

@Test func exportWithOnlyIncompleteAnnotationsUsesLegacyPath() {
    let frozen = markedImage(400)
    let px = CGRect(x: 0, y: 0, width: 400, height: 400)
    let legacy = ImageCodec.png(ImageCodec.crop(frozen, pixelRect: px)!)
    let half = Annotation(tool: .pen, points: [CGPoint(x: 5, y: 5)],
                          color: .pureRed, lineWidth: 2)
    let out = AnnotationCompositor.exportPNG(frozen: frozen, pixelRect: px, annotations: [half],
                                             scale: 1, selectionOrigin: .zero)!
    #expect(out.data == legacy)
}
