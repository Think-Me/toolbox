import Foundation
import Testing
@testable import ToolboxKit

/// 老配置兼容。重点是**用户机器上真实存在的形状**：
/// 热键在盘上是"键值交替数组"，而且里面带着已删除的 `openSettings`。
/// 用 [HotkeyID: KeyCombo] 直接解码会整份失败 → 配置被静默重置。
@Test func staleOpenSettingsEntryDoesNotKillTheWholeConfig() throws {
    let url = URL(fileURLWithPath: "/tmp/toolbox-migrate-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    // 形状与真实 settings.json 一致（含已删掉的 openSettings）
    let json = """
    {"clipboardCapacity": 333,
     "hotkeys": ["openSettings", {"keyCode":43,"carbonModifiers":6400},
                 "clipboard", {"keyCode":9,"carbonModifiers":768},
                 "captureFull", {"keyCode":120,"carbonModifiers":0}]}
    """
    try json.data(using: .utf8)!.write(to: url)
    let loaded = try SettingsStore(file: url).load()

    #expect(loaded.clipboardCapacity == 333)              // 其它设置没丢
    #expect(loaded.hotkeys[.clipboard]?.displayString == "⇧⌘V")   // 用户改过的键位保留
    #expect(loaded.hotkeys[.captureFull]?.displayString == "F2")
    // 已删除的键位不进结果，缺失的键位补默认值 —— 不会出现"某个功能没有键位"
    #expect(loaded.hotkeys.count == HotkeyID.allCases.count)
    #expect(loaded.hotkeys[.killAllPins]?.displayString == "F3")
    #expect(loaded.hotkeys[.hostsQuick] == AppSettings.default.hotkeys[.hostsQuick])
}

@Test func unknownKeyIsIgnoredNotFatal() throws {
    let url = URL(fileURLWithPath: "/tmp/toolbox-migrate2-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let json = """
    {"hotkeys": ["someFutureFeature", {"keyCode":44,"carbonModifiers":6144},
                 "clipboard", {"keyCode":9,"carbonModifiers":768}]}
    """
    try json.data(using: .utf8)!.write(to: url)
    let loaded = try SettingsStore(file: url).load()
    #expect(loaded.hotkeys[.clipboard]?.displayString == "⇧⌘V")
    #expect(loaded.hotkeys.count == HotkeyID.allCases.count)
}

@Test func hotkeysRoundTripThroughSave() throws {
    // 保存后再读必须一致；顺便确认删除键位后落盘不再带它
    let url = URL(fileURLWithPath: "/tmp/toolbox-roundtrip-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    var settings = AppSettings.default
    settings.hotkeys[.clipboard] = KeyCombo(keyCode: KeyCombo.ansiD,
                                            carbonModifiers: KeyCombo.control)
    let store = SettingsStore(file: url)
    try store.save(settings)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains("openSettings"))
    let loaded = try store.load()
    #expect(loaded == settings)
}
