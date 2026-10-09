import CoreGraphics
import Foundation
import Testing
@testable import ToolboxKit

private func solidImage(_ w: Int, _ h: Int, color: [CGFloat] = [1, 0, 0, 1]) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(colorSpace: cs, components: color)!)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

@Test func cropReturnsExactRequestedSize() {
    let img = solidImage(200, 100)
    let out = ImageCodec.crop(img, pixelRect: CGRect(x: 10, y: 20, width: 50, height: 30))
    #expect(out?.width == 50)
    #expect(out?.height == 30)
}

@Test func cropClampsOverflowInsteadOfCrashing() {
    let img = solidImage(100, 100)
    let out = ImageCodec.crop(img, pixelRect: CGRect(x: 80, y: 80, width: 500, height: 500))
    #expect(out != nil)
    #expect(CGSize(width: out!.width, height: out!.height) == CGSize(width: 20, height: 20))
}

@Test func cropRejectsFullyOutOfBounds() {
    let img = solidImage(100, 100)
    #expect(ImageCodec.crop(img, pixelRect: CGRect(x: 500, y: 500, width: 10, height: 10)) == nil)
}

@Test func cropOfOnePixelWorks() {
    let img = solidImage(10, 10)
    let out = ImageCodec.crop(img, pixelRect: CGRect(x: 5, y: 5, width: 1, height: 1))
    #expect(out?.width == 1 && out?.height == 1)
}

@Test func pngRoundTripKeepsDimensions() throws {
    let img = solidImage(64, 32)
    let data = try #require(ImageCodec.png(img))
    #expect(try #require(ImageCodec.pixelSize(ofPNG: data)) == CGSize(width: 64, height: 32))
}

@Test func downsampleOnlyShrinks() throws {
    let data = try #require(ImageCodec.png(solidImage(400, 200)))
    let smaller = try #require(ImageCodec.downsample(data, maxPixel: 100))
    #expect(try #require(ImageCodec.pixelSize(ofPNG: smaller)) == CGSize(width: 100, height: 50))
    // maxPixel 比原图还大时不许放大
    let same = try #require(ImageCodec.downsample(data, maxPixel: 5000))
    #expect(try #require(ImageCodec.pixelSize(ofPNG: same)) == CGSize(width: 400, height: 200))
}

@Test func garbageDataReturnsNilNotCrash() {
    let junk = Data("这不是 PNG".utf8)
    #expect(ImageCodec.pixelSize(ofPNG: junk) == nil)
    #expect(ImageCodec.downsample(junk, maxPixel: 10) == nil)
    #expect(ImageCodec.downsample(Data(), maxPixel: 10) == nil)
}

@Test func pixelSizeRejectsEmptyData() {
    #expect(ImageCodec.pixelSize(ofPNG: Data()) == nil)
}
