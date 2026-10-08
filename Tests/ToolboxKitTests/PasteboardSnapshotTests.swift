import AppKit
import Testing
@testable import ToolboxKit

private func snap(types: [NSPasteboard.PasteboardType],
                  text: String? = nil, urls: [URL] = [],
                  image: Data? = nil, pixelSize: CGSize? = nil) -> PasteboardSnapshot {
    PasteboardSnapshot(types: types, text: text, fileURLs: urls,
                       imageData: image, pixelSize: pixelSize)
}

@Test func fileURLsBeatImageAndText() throws {
    let s = snap(types: [.fileURL, .png, .string], text: "fallback",
                 urls: [URL(fileURLWithPath: "/tmp/a.png")],
                 image: Data([0x89, 0x50]), pixelSize: CGSize(width: 1, height: 1))
    let c = try #require(PasteboardNormalizer.normalize(s))
    #expect(c.kind == .fileURLs)
    #expect(c.fileURLs.count == 1)
}

@Test func imageBeatsText() throws {
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let s = snap(types: [.png, .string], text: "路径文字", image: png,
                 pixelSize: CGSize(width: 10, height: 4))
    let c = try #require(PasteboardNormalizer.normalize(s))
    #expect(c.kind == .image)
    #expect(c.pngData == png)
    #expect(c.pixelSize == CGSize(width: 10, height: 4))
    #expect(c.byteLength == png.count)
}

@Test func plainTextIsLastResort() throws {
    let s = snap(types: [.string], text: "just text")
    let c = try #require(PasteboardNormalizer.normalize(s))
    #expect(c.kind == .text)
    #expect(c.text == "just text")
    #expect(c.byteLength == 9)
}

@Test func tiffOnlyGetsConvertedToPNG() throws {
    // 很多 App（截图工具、Office）只放 TIFF，不转成 PNG 就没法存内容寻址文件
    let img = NSImage(size: NSSize(width: 4, height: 3), flipped: false) { rect in
        NSColor.red.setFill(); rect.fill(); return true
    }
    guard let tiff = img.tiffRepresentation else { Issue.record("造不出 TIFF"); return }
    let s = snap(types: [NSPasteboard.PasteboardType.tiff], image: tiff,
                 pixelSize: CGSize(width: 4, height: 3))
    let c = try #require(PasteboardNormalizer.normalize(s))
    #expect(c.kind == .image)
    guard let png = c.pngData else { Issue.record("没有 pngData"); return }
    // PNG 魔数
    #expect([UInt8](png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
    #expect(png.count != tiff.count)
}

@Test func undecodableImageYieldsNilNotCrash() {
    let s = snap(types: [.png], image: Data("这不是图片".utf8))
    #expect(PasteboardNormalizer.normalize(s) == nil)
}

@Test func fileURLsAreDedupedOrderPreserved() throws {
    let a = URL(fileURLWithPath: "/tmp/a"), b = URL(fileURLWithPath: "/tmp/b")
    let s = snap(types: [.fileURL], urls: [a, b, a, b, a])
    let c = try #require(PasteboardNormalizer.normalize(s))
    #expect(c.fileURLs == [a, b])
    // 搜索文本里不许出现换行，否则列表一行变两行
    #expect(c.text?.contains("\n") == false)
}

@Test func emptyEverythingYieldsNil() {
    #expect(PasteboardNormalizer.normalize(snap(types: [])) == nil)
    #expect(PasteboardNormalizer.normalize(snap(types: [.string], text: "")) == nil)
    #expect(PasteboardNormalizer.normalize(snap(types: [.fileURL])) == nil)
}

@Test func snapshotFromPasteboardReadsRealGeneralBoard() async throws {
    // 真 NSPasteboard 的薄壳只测"读得回来"，不测归一化（上面已测）
    let pb = NSPasteboard(name: .init("toolbox.probe.\(UUID().uuidString)"))
    pb.clearContents()
    pb.setString("hello board", forType: .string)
    let s = PasteboardSnapshot.read(from: pb)
    #expect(s.text == "hello board")
    #expect(s.types.contains(.string))
    #expect(s.fileURLs.isEmpty)
}

@Test func ownWriteMarkerIsReadOutOfPasteboard() {
    let pb = NSPasteboard(name: .init("toolbox.probe.\(UUID().uuidString)"))
    pb.clearContents()
    pb.setString("x", forType: .string)
    pb.setString("item-42", forType: .ownWrite)
    #expect(PasteboardSnapshot.read(from: pb).ownWriteMarker == "item-42")

    pb.clearContents()
    pb.setString("y", forType: .string)
    #expect(PasteboardSnapshot.read(from: pb).ownWriteMarker == nil)
}

@Test func concealedTypeIsVisibleInSnapshotTypes() {
    let pb = NSPasteboard(name: .init("toolbox.probe.\(UUID().uuidString)"))
    pb.clearContents()
    pb.setString("secret", forType: .string)
    pb.setString("", forType: .concealed)
    let s = PasteboardSnapshot.read(from: pb)
    #expect(s.types.contains(.concealed))
}
