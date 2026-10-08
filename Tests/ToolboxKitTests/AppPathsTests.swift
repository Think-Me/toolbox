import Testing
import Foundation
@testable import ToolboxKit

@Test func dataRootIsUnderAppSupport() throws {
    let root = URL(fileURLWithPath: "/tmp/toolbox-test-\(UUID().uuidString)")
    let p = AppPaths(root: root)
    #expect(p.database.appendingPathExtension("db").lastPathComponent == "Toolbox.db")
    #expect(p.settings.lastPathComponent == "settings.json")
    #expect(p.mediaDirectory.lastPathComponent == "Media")
    #expect(p.hostsBackupDirectory.pathComponents.suffix(2) == ["Hosts", "backup"])
}

@Test func standardRootUsesToolboxFolder() {
    let p = AppPaths.standard()
    #expect(p.root.lastPathComponent == "Toolbox")
    #expect(p.root.path.contains("Library/Application Support"))
}

@Test func ensureDirectoriesAreIdempotent() throws {
    let root = URL(fileURLWithPath: "/tmp/toolbox-test-\(UUID().uuidString)")
    let p = AppPaths(root: root)
    try p.ensureDirectories()
    try p.ensureDirectories()          // 第二次不得抛
    #expect(FileManager.default.fileExists(atPath: p.mediaDirectory.path))
    #expect(FileManager.default.fileExists(atPath: p.hostsBackupDirectory.path))
    try? FileManager.default.removeItem(at: root)
}
