import Testing
import Foundation
@testable import ToolboxKit

private func tmpURL() -> URL {
    URL(fileURLWithPath: "/tmp/toolbox-settings-\(UUID().uuidString).json")
}

@Test func missingFileYieldsDefaults() throws {
    let loaded = try SettingsStore(file: tmpURL()).load()
    #expect(loaded.clipboardCapacity == 500)
    #expect(loaded.hotkeys[.captureRegion]?.displayString == "⌃⌘A")
    #expect(loaded.hotkeys[.clipboard]?.displayString == "⇧⌘V")
    #expect(loaded.hotkeys[.hostsQuick]?.displayString == "⇧⌘H")
}

@Test func roundTripPreservesEverything() throws {
    let f = tmpURL(); defer { try? FileManager.default.removeItem(at: f) }
    let s = SettingsStore(file: f)
    var settings = try s.load()
    settings.clipboardCapacity = 42
    settings.hotkeys[.hostsQuick] = KeyCombo(keyCode: KeyCombo.ansiH,
                                             carbonModifiers: KeyCombo.cmd | KeyCombo.option)
    try s.save(settings)
    let again = try SettingsStore(file: f).load()
    #expect(again.clipboardCapacity == 42)
    #expect(again.hotkeys[.hostsQuick]?.displayString == "⌥⌘H")
}

@Test func unknownFutureKeysAreTolerated() throws {
    let f = tmpURL(); defer { try? FileManager.default.removeItem(at: f) }
    var s = AppSettings.default
    s.clipboardCapacity = 7
    try SettingsStore(file: f).save(s)

    guard let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as? [String: Any] else {
        Issue.record("顶层应是 object"); return
    }
    var mutated = obj
    mutated["someBrandNewFieldFromTheFuture"] = 123
    try JSONSerialization.data(withJSONObject: mutated).write(to: f)

    let loaded = try SettingsStore(file: f).load()
    #expect(loaded.clipboardCapacity == 7)                            // 未知字段被忽略
    #expect(loaded.hotkeys[.captureRegion]?.displayString == "⌃⌘A")  // 已知字段完整读出
}

@Test func corruptFileIsQuarantinedNotCrash() throws {
    let f = tmpURL(); defer { try? FileManager.default.removeItem(at: f) }
    try Data("not json at all {{{".utf8).write(to: f)
    let loaded = try SettingsStore(file: f).load()
    #expect(loaded == .default)
    // 隔离副本 settings.json.corrupt-<ts> 必须存在，原件不许删（要留着取证）
    let dir = f.deletingLastPathComponent()
    let quarantined = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasPrefix(f.lastPathComponent + ".corrupt-") }
    #expect(quarantined.count == 1)
    #expect(FileManager.default.fileExists(atPath: f.path))
    try? FileManager.default.removeItem(atPath: quarantined[0])
}

@Test func saveCreatesParentDirectory() throws {
    let root = URL(fileURLWithPath: "/tmp/toolbox-savedir-\(UUID().uuidString)")
    let f = root.appendingPathComponent("settings.json")
    defer { try? FileManager.default.removeItem(at: root) }
    try SettingsStore(file: f).save(.default)
    #expect(FileManager.default.fileExists(atPath: f.path))
}
