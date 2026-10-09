import CoreGraphics
import Foundation
import Testing
@testable import ToolboxKit

// MARK: 归一化

@Test func normalizeHandlesAllFourDragDirections() {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let cases: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 400)),   // 右下
        (CGPoint(x: 300, y: 400), CGPoint(x: 100, y: 100)),   // 左上
        (CGPoint(x: 100, y: 400), CGPoint(x: 300, y: 100)),   // 右上
        (CGPoint(x: 300, y: 100), CGPoint(x: 100, y: 400)),   // 左下
    ]
    for (a, b) in cases {
        let r = SelectionGeometry.normalize(from: a, to: b, in: bounds)
        #expect(r == CGRect(x: 100, y: 100, width: 200, height: 300), "拖拽方向不该影响结果")
    }
}

@Test func zeroSizeSelectionGetsMinimumOnePoint() {
    let r = SelectionGeometry.normalize(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50),
                                        in: CGRect(x: 0, y: 0, width: 100, height: 100))
    #expect(r.width >= 1 && r.height >= 1)
}

@Test func normalizeClampsToScreenBounds() {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let r = SelectionGeometry.normalize(from: CGPoint(x: -50, y: -50),
                                        to: CGPoint(x: 2000, y: 2000), in: bounds)
    #expect(r == bounds)
}

@Test func negativeOriginScreenIsClampedCorrectly() {
    // 左副屏：x 为负
    let bounds = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let r = SelectionGeometry.normalize(from: CGPoint(x: -100, y: 50),
                                        to: CGPoint(x: 5000, y: 5000), in: bounds)
    #expect(r.maxX <= bounds.maxX + 0.001)
    #expect(r.maxY <= bounds.maxY + 0.001)
}

// MARK: points → pixels

@Test(arguments: [(0.0, 1.0), (0.0, 2.0), (-1920.0, 1.0), (-1920.0, 2.0)])
func pointsToPixelsAcrossScreenAndScaleCombos(screenX: Double, scale: Double) {
    let screen = CGRect(x: screenX, y: 0, width: 1512, height: 982)
    let sel = CGRect(x: screenX + 100, y: 200, width: 50, height: 40)
    let px = SelectionGeometry.pointsToPixels(sel, screenFrame: screen, scale: CGFloat(scale))
    // AppKit 原点在左下、y 向上；CGImage 裁剪用顶原点，所以 Y 要翻。
    // 副屏的 x 偏移要减掉屏原点，得到屏内相对坐标。
    #expect(px == CGRect(x: (100 * scale), y: ((982 - 200 - 40) * scale),
                         width: 50 * scale, height: 40 * scale))
}

@Test func pointsToPixelsClampsOutOfRangeSelection() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let px = SelectionGeometry.pointsToPixels(CGRect(x: 900, y: 900, width: 500, height: 500),
                                              screenFrame: screen, scale: 2)
    #expect(px.maxX <= 2000 + 0.001)
    #expect(px.maxY <= 2000 + 0.001)
    #expect(px.width > 0 && px.height > 0)
}

// MARK: 缩放

@Test func clampZoomRespectsBounds() {
    #expect(SelectionGeometry.clampZoom(0.01, min: 0.2, max: 8) == 0.2)
    #expect(SelectionGeometry.clampZoom(99, min: 0.2, max: 8) == 8)
    #expect(SelectionGeometry.clampZoom(2.5, min: 0.2, max: 8) == 2.5)
}

@Test func zoomedFrameKeepsCenterFixed() {
    let before = SelectionGeometry.zoomedFrame(contentOrigin: CGPoint(x: 100, y: 100),
                                               intrinsic: CGSize(width: 200, height: 100),
                                               zoom: 1)
    let after = SelectionGeometry.zoomedFrame(contentOrigin: CGPoint(x: 100, y: 100),
                                              intrinsic: CGSize(width: 200, height: 100),
                                              zoom: 2)
    #expect(abs(before.midX - after.midX) < 0.001)
    #expect(abs(before.midY - after.midY) < 0.001)
    #expect(after.width == 400 && after.height == 200)
}

@Test func zoomedFrameRoundTripsToOriginalAtZoomOne() {
    let f = SelectionGeometry.zoomedFrame(contentOrigin: CGPoint(x: 33, y: 44),
                                          intrinsic: CGSize(width: 120, height: 80), zoom: 1)
    #expect(f == CGRect(x: 33, y: 44, width: 120, height: 80))
}

// MARK: 屏幕内钳制

@Test func clampedFrameStaysInsideVisibleArea() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)   // 顶部有菜单栏
    let r = SelectionGeometry.clampedToScreen(CGRect(x: 1500, y: 970, width: 200, height: 100),
                                              screen: screen, visible: visible)
    #expect(r.maxX <= visible.maxX + 0.001)
    #expect(r.maxY <= visible.maxY + 0.001)
}

@Test func oversizedFramePrefersTopLeftOverNegativeOrigin() {
    // 贴图比屏幕还大时，至少保证左上角可见、能拖回来
    let screen = CGRect(x: 0, y: 0, width: 500, height: 500)
    let r = SelectionGeometry.clampedToScreen(CGRect(x: 400, y: 400, width: 900, height: 900),
                                              screen: screen, visible: screen)
    #expect(r.minX <= 0.001)
    #expect(r.minY <= 0.001)
}

// MARK: 操作条翻边

// AppKit 坐标 y 向上：屏幕"下方"= y 更小。

@Test func actionStripSitsBelowSelectionWhenRoom() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let sel = CGRect(x: 100, y: 500, width: 200, height: 30)
    let r = SelectionGeometry.stripFrame(for: sel, strip: CGSize(width: 240, height: 32),
                                         screen: screen)
    #expect(r.maxY <= sel.minY + 0.001)      // 贴在选区下沿之下
}

@Test func actionStripFlipsAboveWhenNoRoomBelow() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let sel = CGRect(x: 100, y: 10, width: 200, height: 30)      // 贴屏幕底边
    let r = SelectionGeometry.stripFrame(for: sel, strip: CGSize(width: 240, height: 32),
                                         screen: screen)
    #expect(r.minY >= sel.maxY - 0.001)      // 翻到选区上方
}

@Test func actionStripHorizontallyClamped() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let sel = CGRect(x: 950, y: 500, width: 40, height: 30)
    let r = SelectionGeometry.stripFrame(for: sel, strip: CGSize(width: 240, height: 32),
                                         screen: screen)
    #expect(r.maxX <= screen.maxX + 0.001)
}

@Test func flippedRectToPixelsDoesNotFlipY() {
    // 遮罩视图本身是左上原点：选区在屏幕顶部 → 像素 y 必须接近 0，
    // 而不是被再翻一次跑到图像底部
    let px = SelectionGeometry.flippedRectToPixels(CGRect(x: 10, y: 0, width: 20, height: 30),
                                                   scale: 2)
    #expect(px == CGRect(x: 20, y: 0, width: 40, height: 60))
    let bottom = SelectionGeometry.flippedRectToPixels(CGRect(x: 0, y: 900, width: 10, height: 10),
                                                       scale: 2)
    #expect(bottom.minY == 1800)
}

@Test func flippedAndAppKitConversionsDifferOnY() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let appkit = SelectionGeometry.pointsToPixels(CGRect(x: 100, y: 600, width: 50, height: 50),
                                                  screenFrame: screen, scale: 1)
    // AppKit y=600（靠近顶部）→ 顶原点 y = 800-600-50 = 150
    #expect(appkit.minY == 150)
    let flipped = SelectionGeometry.flippedRectToPixels(CGRect(x: 100, y: 600, width: 50, height: 50),
                                                        scale: 1)
    // 顶原点 y=600 就是 600，不翻
    #expect(flipped.minY == 600)
}
