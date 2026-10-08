import Foundation
import Testing
@testable import ToolboxKit

private func tempDir() -> URL {
    URL(fileURLWithPath: "/tmp/toolbox-media-\(UUID().uuidString)", isDirectory: true)
}

@Test func storeIsContentAddressedAndDedupes() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let m = MediaStore(directory: dir)
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let sha1 = try m.store(png: png)
    let sha2 = try m.store(png: png)
    #expect(sha1 == sha2)
    #expect(sha1 == SHA256.hex(png))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
}

@Test func storedFileNameIsSHAWithPNGExtension() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let m = MediaStore(directory: dir)
    let sha = try m.store(png: Data("x".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["\(sha).png"])
}

@Test func dataRoundTrips() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let m = MediaStore(directory: dir)
    let payload = Data((0...255).map { UInt8($0) })
    let sha = try m.store(png: payload)
    #expect(try m.data(sha: sha) == payload)
    #expect(try m.data(sha: SHA256.hex(Data("missing".utf8))) == nil)
}

@Test func rejectsPathTraversalViaSHAArgument() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let outside = dir.deletingLastPathComponent().appendingPathComponent("toolbox-victim.png")
    try "victim".data(using: .utf8)!.write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }

    let m = MediaStore(directory: dir)
    // sha 参数来自 DB 行，可能被手工改过；非纯 hex 必须拒绝而不是拼路径
    #expect(try m.data(sha: "../../toolbox-victim") == nil)
    #expect(try m.data(sha: "/etc/hosts") == nil)
    #expect(try m.data(sha: "") == nil)
    #expect(try m.delete(sha: "../../toolbox-victim") == false)
    #expect(FileManager.default.fileExists(atPath: outside.path))   // 没被碰到
}

@Test func garbageCollectKeepsLiveAndDropsRest() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let m = MediaStore(directory: dir)
    let keep = try m.store(png: Data("keep".utf8))
    let drop1 = try m.store(png: Data("drop1".utf8))
    let drop2 = try m.store(png: Data("drop2".utf8))

    let removed = try m.garbageCollect(liveSHAs: [keep])
    #expect(removed == 2)
    #expect(try m.data(sha: keep) != nil)
    #expect(try m.data(sha: drop1) == nil)
    #expect(try m.data(sha: drop2) == nil)
}

@Test func garbageCollectWithEmptyLiveSetClearsEverything() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let m = MediaStore(directory: dir)
    _ = try m.store(png: Data("a".utf8))
    _ = try m.store(png: Data("b".utf8))
    #expect(try m.garbageCollect(liveSHAs: []) == 2)
    #expect(try m.allSHAs().isEmpty)
}

@Test func gcIgnoresUnrelatedFilesAndKeepsGoing() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "junk".data(using: .utf8)!.write(to: dir.appendingPathComponent("notes.txt"))
    let keep = try MediaStore(directory: dir).store(png: Data("k".utf8))
    let removed = try MediaStore(directory: dir).garbageCollect(liveSHAs: [keep])
    #expect(removed == 0)
    // 非 <64hex>.png 的文件不归它管，不许顺手删
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.txt").path))
}

@Test func storeCreatesMissingDirectory() throws {
    let dir = tempDir().appendingPathComponent("nested/deeper", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempParent(of: dir)) }
    let m = MediaStore(directory: dir)
    let sha = try m.store(png: Data("n".utf8))
    #expect(try m.data(sha: sha) != nil)
}

@Test func totalBytesSumsStoredFiles() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let m = MediaStore(directory: dir)
    _ = try m.store(png: Data(repeating: 0, count: 100))
    _ = try m.store(png: Data(repeating: 1, count: 50))
    #expect(try m.totalBytes() == 150)
}

private func tempParent(of url: URL) -> URL { url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

@Test func plausibleHexValidatorIsStrict() {
    #expect(SHA256.isPlausibleHex(String(repeating: "a", count: 64)))
    #expect(!SHA256.isPlausibleHex(String(repeating: "A", count: 64)))   // 大写不算，文件名统一小写
    #expect(!SHA256.isPlausibleHex(String(repeating: "g", count: 64)))
    #expect(!SHA256.isPlausibleHex("../x"))
    #expect(!SHA256.isPlausibleHex(""))
}
