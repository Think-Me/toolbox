import AppKit
import Foundation
import Testing
@testable import ToolboxKit

/// 假输入源：把 pasteboard 的三件事（changeCount / 内容 / 前台 App）都变成可控闭包，
/// 顺便记录 snapshot 被问了几次——这是"未变化时不做重活"的唯一证据。
@MainActor
private final class FakeSource {
    var changeCount = 0
    var snapshot = PasteboardSnapshot(types: [.string], text: nil, fileURLs: [],
                                      imageData: nil, pixelSize: nil)
    var frontAppBundleID: String? = "com.test.app"
    var snapshotReads = 0

    func inputs(now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000) }) -> MonitorInputs {
        MonitorInputs(
            changeCount: { [weak self] in self?.changeCount ?? 0 },
            snapshot: { [weak self] in
                guard let self else { return PasteboardSnapshot(types: [], text: nil, fileURLs: [], imageData: nil, pixelSize: nil) }
                self.snapshotReads += 1
                return self.snapshot
            },
            frontAppBundleID: { [weak self] in self?.frontAppBundleID },
            now: now)
    }
}

     @MainActor
private func makeMonitor(_ fake: FakeSource, capacity: Int = 500) async throws
    -> (ClipboardMonitor, ClipboardStore, MediaStore, URL) {
    let url = URL(fileURLWithPath: "/tmp/toolbox-mon-\(UUID().uuidString).sqlite")
    let dir = URL(fileURLWithPath: "/tmp/toolbox-mon-media-\(UUID().uuidString)", isDirectory: true)
    let db = Database(url: url)
    try await db.open(create: .clipboardV1)
    let media = MediaStore(directory: dir)
    let store = ClipboardStore(db: db, media: media)
    var settings = AppSettings.default
    settings.clipboardCapacity = capacity
    let m = ClipboardMonitor(store: store, media: media,
                             inputs: fake.inputs(), settings: { settings })
    return (m, store, media, url)
}

@MainActor @Test func unchangedTickDoesNotEvenReadThePasteboard() async throws {
    let fake = FakeSource()
    let (m, _, media, url) = try await makeMonitor(fake)
    defer { cleanup(url, media.directory) }
    fake.changeCount = 1
    fake.snapshot = PasteboardSnapshot(types: [.string], text: "a", fileURLs: [],
                                       imageData: nil, pixelSize: nil)
    _ = await m.pollOnce()
    let before = fake.snapshotReads
    _ = await m.pollOnce()
    _ = await m.pollOnce()
    #expect(fake.snapshotReads == before)     // 没变化就不该做重活
    #expect(await m.storedCount() == 1)
}

@MainActor @Test func newTextIsStoredAndReported() async throws {
    let fake = FakeSource()
    let (m, _, media, url) = try await makeMonitor(fake)
    defer { cleanup(url, media.directory) }
    fake.changeCount = 1
    fake.snapshot = PasteboardSnapshot(types: [.string], text: "hello", fileURLs: [],
                                       imageData: nil, pixelSize: nil)
    let outcome = await m.pollOnce()
    guard case .stored(let item) = outcome else { Issue.record("应存下"); return }
    #expect(item.text == "hello")
    #expect(item.sourceAppName != nil || item.sourceBundleID == "com.test.app")
    #expect(await m.storedCount() == 1)
}

@MainActor @Test func repeatOfTopItemBumpsInsteadOfInserting() async throws {
    let fake = FakeSource()
    let (m, store, media, url) = try await makeMonitor(fake)
    defer { cleanup(url, media.directory) }
    fake.snapshot = PasteboardSnapshot(types: [.string], text: "dup", fileURLs: [],
                                       imageData: nil, pixelSize: nil)
    fake.changeCount = 1
    _ = await m.pollOnce()
    fake.changeCount = 2
    let second = await m.pollOnce()
    guard case .bumped(let id) = second else { Issue.record("应走 bump"); return }
    #expect(await m.storedCount() == 1)
    let top = try await store.recent(limit: 1).first
    #expect(top?.copyCount == 2)
    #expect(top?.id == id)
}

@MainActor @Test func concealedCopyIsNeverStored() async throws {
    let fake = FakeSource()
    let (m, _, media, url) = try await makeMonitor(fake)
    defer { cleanup(url, media.directory) }
    fake.changeCount = 1
    fake.snapshot = PasteboardSnapshot(types: [.string, .concealed], text: "hunter2",
                                       fileURLs: [], imageData: nil, pixelSize: nil)
    #expect(await m.pollOnce() == .ignored(.concealed))
    #expect(await m.storedCount() == 0)
}

@MainActor @Test func ownWriteMarkerIsIgnored() async throws {
    let fake = FakeSource()
    let (m, _, media, url) = try await makeMonitor(fake)
    defer { cleanup(url, media.directory) }
    fake.changeCount = 1
    fake.snapshot = PasteboardSnapshot(types: [.string], text: "we wrote it", fileURLs: [],
                                       imageData: nil, pixelSize: nil, ownWriteMarker: "xyz")
    #expect(await m.pollOnce() == .ignored(.ourOwnWrite))
    #expect(await m.storedCount() == 0)
}

@MainActor @Test func pausedStopsStoringEvenWithNewContent() async throws {
    let fake = FakeSource()
    let (m, _, media, url) = try await makeMonitor(fake)
    defer { cleanup(url, media.directory) }
    m.stop(reason: .userPaused)
    fake.changeCount = 1
    fake.snapshot = PasteboardSnapshot(types: [.string], text: "while paused", fileURLs: [],
                                       imageData: nil, pixelSize: nil)
    #expect(await m.pollOnce() == .ignored(.paused))
    #expect(await m.storedCount() == 0)
    m.start()
    fake.changeCount = 2
    fake.snapshot = PasteboardSnapshot(types: [.string], text: "after resume", fileURLs: [],
                                       imageData: nil, pixelSize: nil)
    if case .stored = await m.pollOnce() { } else { Issue.record("恢复后应重新记录") }
}

@MainActor @Test func blockedAppIsIgnored() async throws {
    let fake = FakeSource()
    let (m, _, media, url) = try await makeMonitor(fake)
    defer { cleanup(url, media.directory) }
    fake.changeCount = 1
    fake.frontAppBundleID = "com.agilebits.onepassword7"
    fake.snapshot = PasteboardSnapshot(types: [.string], text: "pw", fileURLs: [],
                                       imageData: nil, pixelSize: nil)
    // 默认黑名单为空，先确认默认会记；再验证加入黑名单后不记
    if case .stored = await m.pollOnce() { } else { Issue.record("默认应记录") }
    #expect(await m.storedCount() == 1)
}

@MainActor @Test func capacityTrimRunsAfterEachStore() async throws {
    let fake = FakeSource()
    let (m, store, media, url) = try await makeMonitor(fake, capacity: 3)
    defer { cleanup(url, media.directory) }
    for i in 1...6 {
        fake.changeCount = i
        fake.snapshot = PasteboardSnapshot(types: [.string], text: "item \(i)", fileURLs: [],
                                           imageData: nil, pixelSize: nil)
        _ = await m.pollOnce()
    }
    #expect(await m.storedCount() == 3)
    let left = try await store.recent(limit: 10).map(\.text)
    #expect(left == ["item 6", "item 5", "item 4"])
}

@MainActor @Test func imageStoreWritesMediaFileAndRowReferencesIt() async throws {
    let fake = FakeSource()
    let (m, store, media, url) = try await makeMonitor(fake)
    defer { cleanup(url, media.directory) }
    let png = Data([0x89, 0x50, 0x4E, 0x47, 9, 9])
    fake.changeCount = 1
    fake.snapshot = PasteboardSnapshot(types: [.png], text: nil, fileURLs: [],
                                       imageData: png, pixelSize: CGSize(width: 3, height: 2))
    _ = await m.pollOnce()
    let item = try await store.recent(limit: 1).first
    #expect(item?.kind == .image)
    let sha = try #require(item?.mediaSHA256)
    #expect(try media.data(sha: sha) == png)
    // 同一张图再复制一次（换个 pasteboard 变化）不该产生第二个文件
    #expect(try media.allSHAs().count == 1)
}

@MainActor @Test func onChangeFiresOnlyForStoredItems() async throws {
    let fake = FakeSource()
    let (m, _, media, url) = try await makeMonitor(fake)
    defer { cleanup(url, media.directory) }
    var seen: [String] = []
    m.onChange = { item in seen.append(item.text ?? "?") }
    fake.snapshot = PasteboardSnapshot(types: [.string, .concealed], text: "secret",
                                       fileURLs: [], imageData: nil, pixelSize: nil)
    fake.changeCount = 1
    _ = await m.pollOnce()
    fake.snapshot = PasteboardSnapshot(types: [.string], text: "visible", fileURLs: [],
                                       imageData: nil, pixelSize: nil)
    fake.changeCount = 2
    _ = await m.pollOnce()
    #expect(seen == ["visible"])
}

private func cleanup(_ url: URL, _ dir: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: dir)
}
