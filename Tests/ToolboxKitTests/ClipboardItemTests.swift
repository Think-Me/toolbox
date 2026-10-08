import Testing
import Foundation
@testable import ToolboxKit

private func makeTextItem(_ s: String = "hello") -> ClipboardItem {
    ClipboardItem(text: s, sourceBundleID: "com.test", sourceAppName: "Test",
                  at: Date(timeIntervalSince1970: 1_700_000_000))
}

@Test func textItemRoundTripsThroughRow() throws {
    var item = makeTextItem("第一行\n第二行")
    item.copyCount = 3
    let row = item.asRow()
    let back = try ClipboardItem(row: row)
    #expect(back.id == item.id)
    #expect(back.kind == .text)
    #expect(back.text == "第一行\n第二行")
    #expect(back.copyCount == 3)
    #expect(back.pinned == false)
    #expect(back.lastCopiedAt == item.lastCopiedAt)
}

@Test func fileURLsRoundTripPreservesOrderAndNewlines() throws {
    // 文件名里带换行是合法的，用 \n 连接会把一条路径切成两条
    let urls = [URL(fileURLWithPath: "/tmp/a\nb.txt"),
                URL(fileURLWithPath: "/tmp/中文 目录/x.png"),
                URL(fileURLWithPath: "/tmp/second")]
    let item = ClipboardItem(fileURLs: urls, sourceBundleID: "Finder",
                             sourceAppName: "访达",
                             at: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(item.kind == .fileURLs)
    let back = try ClipboardItem(row: item.asRow())
    #expect(back.fileURLs?.count == 3)
    #expect(back.fileURLs?.map(\.path) == urls.map(\.path))
    // 搜索用的拼接串必须把换行折掉，否则列表里一行变两行
    #expect(back.text?.contains("\n") == false)
}

@Test func imageItemKeepsSHAAndPixelSize() throws {
    let item = ClipboardItem(imagePNG: Data([0x89, 0x50]), sha256: "abc123",
                             pixelSize: CGSize(width: 2560, height: 1440),
                             sourceBundleID: "com.test", sourceAppName: "Test",
                             at: Date(timeIntervalSince1970: 1_700_000_000))
    let back = try ClipboardItem(row: item.asRow())
    #expect(back.kind == .image)
    #expect(back.mediaSHA256 == "abc123")
    #expect(back.pixelSize == CGSize(width: 2560, height: 1440))
    #expect(back.byteLength == 2)
}

@Test func persistedKindStringsAreStable() {
    // 这些字符串已经写进用户的 DB，改了就读不出旧数据，必须有测试挡着
    #expect(ClipboardKind.text.rawValue == "text")
    #expect(ClipboardKind.image.rawValue == "image")
    #expect(ClipboardKind.fileURLs.rawValue == "fileURLs")
}

@Test func displayPreviewFoldsNewlinesAndTruncates() {
    #expect(makeTextItem("a\nb\nc").displayPreview == "a b c")
    let long = String(repeating: "字", count: 300)
    let p = makeTextItem(long).displayPreview
    #expect(p.count <= 140)
    #expect(p.hasSuffix("…"))
    #expect(makeTextItem("").displayPreview.isEmpty)
}

@Test func displayPreviewForNonTextKindsIsLabelled() {
    let img = ClipboardItem(imagePNG: Data([1]), sha256: "s", pixelSize: CGSize(width: 10, height: 20),
                            sourceBundleID: nil, sourceAppName: nil,
                            at: Date(timeIntervalSince1970: 0))
    #expect(img.displayPreview.contains("图片"))
    #expect(img.displayPreview.contains("10"))
    let files = ClipboardItem(fileURLs: [URL(fileURLWithPath: "/tmp/x")], sourceBundleID: nil,
                              sourceAppName: nil, at: Date(timeIntervalSince1970: 0))
    #expect(files.displayPreview.contains("文件"))
}

@Test func insertArgumentsMatchColumnCountAndOrder() throws {
    let item = makeTextItem("x")
    let cols = ClipboardItem.insertColumns
    let args = item.insertArguments()
    #expect(cols.count == args.count)
    #expect(cols.first == "id")
    #expect(cols.contains("last_copied_at"))
    // 占位符数量必须与列数一致，否则 SQL 直接错位
    #expect(ClipboardItem.insertPlaceholders.filter { $0 == "?" }.count == cols.count)
}

@Test func unknownKindThrowsInsteadOfGuessing() {
    var cols: [String: DBValue] = [:]
    cols["id"] = .text(UUID().uuidString)
    cols["kind"] = .text("video")           // 未来版本或脏数据
    cols["byte_length"] = .integer(0)
    cols["pinned"] = .integer(0)
    cols["created_at"] = .real(0)
    cols["last_copied_at"] = .real(0)
    cols["copy_count"] = .integer(1)
    #expect(throws: ClipboardItemError.self) {
        _ = try ClipboardItem(row: Row(cols))
    }
}
