import Foundation
import Testing
@testable import ToolboxKit

private func makeStore() async throws -> (ClipboardStore, Database, MediaStore, URL) {
    let url = URL(fileURLWithPath: "/tmp/toolbox-store-\(UUID().uuidString).sqlite")
    let dir = URL(fileURLWithPath: "/tmp/toolbox-store-media-\(UUID().uuidString)", isDirectory: true)
    let db = Database(url: url)
    try await db.open(create: .clipboardV1)
    return (ClipboardStore(db: db, media: MediaStore(directory: dir)), db,
            MediaStore(directory: dir), url)
}

private func cleanup(_ url: URL, _ dir: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: dir)
}

private func textItem(_ s: String, at t: TimeInterval) -> ClipboardItem {
    ClipboardItem(text: s, sourceBundleID: nil, sourceAppName: nil,
                  at: Date(timeIntervalSince1970: t))
}

@Test func recentOrdersByPinnedThenLastCopied() async throws {
    let (store, _, media, url) = try await makeStore()
    defer { cleanup(url, media.directory) }
    let old = textItem("old", at: 100)
    let newest = textItem("new", at: 300)
    let middle = textItem("mid", at: 200)
    try await store.insert(old)
    try await store.insert(newest)
    try await store.insert(middle)
    var pinned = old
    pinned.pinned = true
    try await store.setPinned(id: old.id, true)

    let order = try await store.recent(limit: 10).map(\.text)
    // 置顶优先，其次按最近复制
    #expect(order == ["old", "new", "mid"])
}

@Test func bumpMovesToFrontAndIncrementsCount() async throws {
    let (store, _, media, url) = try await makeStore()
    defer { cleanup(url, media.directory) }
    let a = textItem("a", at: 100)
    let b = textItem("b", at: 200)
    try await store.insert(a)
    try await store.insert(b)
    try await store.bump(id: a.id, at: Date(timeIntervalSince1970: 300))
    let top = try await store.recent(limit: 1).first
    #expect(top?.text == "a")
    #expect(top?.copyCount == 2)
    #expect(top?.lastCopiedAt == Date(timeIntervalSince1970: 300))
    #expect(top?.createdAt == Date(timeIntervalSince1970: 100))   // 创建时间不许被 bump 改掉
}

@Test func trimRemovesOldestUnpinnedOnly() async throws {
    let (store, _, media, url) = try await makeStore()
    defer { cleanup(url, media.directory) }
    for i in 1...5 { try await store.insert(textItem("t\(i)", at: Double(i) * 100)) }
    var keep = textItem("keep", at: 50)          // 最旧但已置顶
    keep.pinned = true
    try await store.insert(keep)

    let removed = try await store.trim(to: 3)
    #expect(removed.deletedRows == 3)
    #expect(removed.deletedMediaSHAs.isEmpty)      // 全是文本行，没有媒体要回收
    let left = try await store.recent(limit: 10).map(\.text)
    #expect(left.count == 3)
    #expect(left.contains("keep"))
    #expect(!left.contains("t1") && !left.contains("t2"))   // 最旧的非置顶先走
}

@Test func trimNeverDeletesWhenPinnedAlreadyExceedsCapacity() async throws {
    // 用户显式收藏的东西不能因为容量设置被丢掉，宁可暂时超容量
    let (store, _, media, url) = try await makeStore()
    defer { cleanup(url, media.directory) }
    for i in 1...4 {
        var it = textItem("p\(i)", at: Double(i) * 100)
        it.pinned = true
        try await store.insert(it)
    }
    let removed = try await store.trim(to: 2)
    #expect(removed.deletedRows == 0)
    #expect(try await store.count() == 4)
}

@Test func trimReturnsMediaSHAsSoCallerCanCollectGarbage() async throws {
    let (store, _, media, url) = try await makeStore()
    defer { cleanup(url, media.directory) }
    let png = Data([0x89, 0x50, 0x4E, 0x47, 1])
    let sha = try media.store(png: png)
    var img = ClipboardItem(imagePNG: png, sha256: sha, pixelSize: CGSize(width: 2, height: 2),
                            sourceBundleID: nil, sourceAppName: nil,
                            at: Date(timeIntervalSince1970: 10))
    img.pinned = false
    try await store.insert(img)
    try await store.insert(textItem("newer", at: 20))
    let trimmed = try await store.trim(to: 1)
    #expect(trimmed.deletedMediaSHAs == [sha])
    #expect(try media.data(sha: sha) == nil)     // GC 已把实体带走
}

@Test func searchMatchesTextAndEscapesWildcards() async throws {
    let (store, _, media, url) = try await makeStore()
    defer { cleanup(url, media.directory) }
    try await store.insert(textItem("100% pure", at: 100))
    try await store.insert(textItem("a_b", at: 200))
    try await store.insert(textItem("axb", at: 300))
    try await store.insert(textItem("中文示例", at: 400))

    #expect(try await store.search("pure", limit: 10).count == 1)
    #expect(try await store.search("中文", limit: 10).count == 1)
    // 不转义的话 % 和 _ 会当通配符：搜 "100%" 会命中所有以 100 开头的行，
    // 搜 "a_b" 会连 "axb" 一起命中
    #expect(try await store.search("100%", limit: 10).map(\.text) == ["100% pure"])
    #expect(try await store.search("a_b", limit: 10).map(\.text) == ["a_b"])
    // 空查询等价于不过滤
    #expect(try await store.search("", limit: 10).count == 4)
    #expect(try await store.search("   ", limit: 10).count == 4)
}

@Test func searchRespectsLimit() async throws {
    let (store, _, media, url) = try await makeStore()
    defer { cleanup(url, media.directory) }
    for i in 0..<10 { try await store.insert(textItem("hit \(i)", at: Double(i))) }
    #expect(try await store.search("hit", limit: 3).count == 3)
}

@Test func deleteRemovesRowAndReportsMedia() async throws {
    let (store, _, media, url) = try await makeStore()
    defer { cleanup(url, media.directory) }
    let png = Data([1, 2, 3])
    let sha = try media.store(png: png)
    try await store.insert(ClipboardItem(imagePNG: png, sha256: sha, pixelSize: nil,
                                         sourceBundleID: nil, sourceAppName: nil,
                                         at: Date(timeIntervalSince1970: 1)))
    let removed = try await store.delete(id: (try await store.recent(limit: 1))[0].id)
    #expect(removed == [sha])
    #expect(try await store.count() == 0)
}

@Test func clearAllReturnsEveryMediaSHA() async throws {
    let (store, _, media, url) = try await makeStore()
    defer { cleanup(url, media.directory) }
    let s1 = try media.store(png: Data("one".utf8))
    let s2 = try media.store(png: Data("two".utf8))
    try await store.insert(ClipboardItem(imagePNG: Data("one".utf8), sha256: s1, pixelSize: nil,
                                         sourceBundleID: nil, sourceAppName: nil,
                                         at: Date(timeIntervalSince1970: 1)))
    try await store.insert(ClipboardItem(imagePNG: Data("two".utf8), sha256: s2, pixelSize: nil,
                                         sourceBundleID: nil, sourceAppName: nil,
                                         at: Date(timeIntervalSince1970: 2)))
    let all = try await store.clearAll()
    #expect(Set(all) == [s1, s2])
    #expect(try await store.count() == 0)
}

@Test func reopeningStoreLoadsSameRows() async throws {
    let url = URL(fileURLWithPath: "/tmp/toolbox-persist-\(UUID().uuidString).sqlite")
    let dir = URL(fileURLWithPath: "/tmp/toolbox-persist-media-\(UUID().uuidString)", isDirectory: true)
    defer { cleanup(url, dir) }
    let db = Database(url: url)
    try await db.open(create: .clipboardV1)
    let first = ClipboardStore(db: db, media: MediaStore(directory: dir))
    try await first.insert(textItem("persisted", at: 100))

    let db2 = Database(url: url)
    try await db2.open(create: .clipboardV1)
    let second = ClipboardStore(db: db2, media: MediaStore(directory: dir))
    let rows = try await second.recent(limit: 5)
    #expect(rows.map(\.text) == ["persisted"])
}

@Test func fileURLsItemRoundTripsThroughStore() async throws {
    let (store, _, media, url) = try await makeStore()
    defer { cleanup(url, media.directory) }
    let item = ClipboardItem(fileURLs: [URL(fileURLWithPath: "/tmp/x\ny.txt")],
                             sourceBundleID: "com.finder", sourceAppName: "访达",
                             at: Date(timeIntervalSince1970: 1))
    try await store.insert(item)
    let back = try await store.recent(limit: 1).first
    #expect(back?.fileURLs?.first?.path == "/tmp/x\ny.txt")
    #expect(back?.kind == .fileURLs)
}

@MainActor @Test func matchingIDFindsDuplicateAnywhereNotJustTop() async throws {
    let (store, _, media, url) = try await makeStore()
    defer { cleanup(url, media.directory) }
    let a = textItem("A", at: 100), b = textItem("B", at: 200)
    try await store.insert(a)
    try await store.insert(b)
    // A 不在栈顶，仍然必须被找到（否则 A、B、A 会插出两条 A）
    #expect(try await store.matchingID(kind: .text, text: "A", sha: nil, paths: nil) == a.id)
    #expect(try await store.matchingID(kind: .text, text: "B", sha: nil, paths: nil) == b.id)
    #expect(try await store.matchingID(kind: .text, text: "C", sha: nil, paths: nil) == nil)
}

@MainActor @Test func matchingIDDoesNotCrossKinds() async throws {
    let (store, _, media, url) = try await makeStore()
    defer { cleanup(url, media.directory) }
    try await store.insert(ClipboardItem(text: "same", sourceBundleID: nil, sourceAppName: nil,
                                         at: Date(timeIntervalSince1970: 1)))
    // 同名的图片/文件不该被文本匹配捞出来
    #expect(try await store.matchingID(kind: .image, text: nil, sha: "same", paths: nil) == nil)
    #expect(try await store.matchingID(kind: .fileURLs, text: nil, sha: nil,
                                       paths: ["same"]) == nil)
}

@MainActor @Test func matchingIDForImagesUsesSHA() async throws {
    let (store, _, media, url) = try await makeStore()
    defer { cleanup(url, media.directory) }
    let png = Data([9, 9, 9])
    let sha = SHA256.hex(png)
    try await store.insert(ClipboardItem(imagePNG: png, sha256: sha, pixelSize: nil,
                                         sourceBundleID: nil, sourceAppName: nil,
                                         at: Date(timeIntervalSince1970: 1)))
    #expect(try await store.matchingID(kind: .image, text: nil, sha: sha, paths: nil) != nil)
    #expect(try await store.matchingID(kind: .image, text: nil, sha: "other", paths: nil) == nil)
}
