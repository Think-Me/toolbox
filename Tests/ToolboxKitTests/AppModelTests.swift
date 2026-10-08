import Carbon.HIToolbox
import CoreGraphics
import AppKit
import Foundation
import Testing
@testable import ToolboxKit

/// 由 CGEvent 造一个真实 NSEvent。不需要任何权限，也不走 HID 投递，
/// 所以能稳定测"键盘 → 录制器 → 设置落盘 → 热键重注册"整条链，
/// 不像合成按键那样受焦点/被别的热键截走等环境因素干扰。
func makeKeyEvent(keyCode: UInt16, carbon: NSEvent.ModifierFlags) -> NSEvent? {
    let ev = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)
    /// NSEvent.ModifierFlags 与 CGEventFlags 的设备无关位取值相同，可直接搬 rawValue
    ev?.flags = CGEventFlags(rawValue: UInt64(carbon.rawValue))
    return ev.flatMap { NSEvent(cgEvent: $0) }
}

@MainActor @Test func recordedKeyFlowsThroughToSettingsAndCallback() throws {
    let file = URL(fileURLWithPath: "/tmp/toolbox-model-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = SettingsStore(file: file)
    let model = AppModel(settings: .default, store: store,
                         permissions: PermissionCenter(probes: .constantDenied),
                         loginItem: LoginItemCoordinator(manager: FakeLoginItem()))
    var callbackSettings: AppSettings?
    model.onHotkeysChanged = { callbackSettings = $0 }

    // 1. 未录制时按键不该改动任何东西
    model.handleRecordedKey(makeKeyEvent(keyCode: 40, carbon: [.control, .command])!)
    #expect(model.recordingID == nil)

    // 2. 进入录制 → 按 ⌃K → 应显示待提交
    model.beginRecording(.clipboard)
    #expect(model.isRecording)
    model.handleRecordedKey(makeKeyEvent(keyCode: 40, carbon: [.control, .command])!)
    #expect(model.settings.hotkeys[.clipboard]?.displayString == "⇧⌘V")  // 未提交前不许改
    #expect(model.recorderMessage?.contains("⌃⌘K") == true)

    // 3. 回车提交 → 设置更新 + 落盘 + 回调触发
    model.handleRecordedKey(makeKeyEvent(keyCode: 36, carbon: [])!)
    #expect(model.settings.hotkeys[.clipboard]?.displayString == "⌃⌘K")
    #expect(callbackSettings?.hotkeys[.clipboard]?.displayString == "⌃⌘K")
    #expect(try SettingsStore(file: file).load().hotkeys[.clipboard]?.displayString == "⌃⌘K")
    #expect(!model.isRecording)
}

@MainActor @Test func escapeDuringRecordingKeepsOldBinding() throws {
    let file = URL(fileURLWithPath: "/tmp/toolbox-model-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let model = AppModel(settings: .default, store: SettingsStore(file: file),
                         permissions: PermissionCenter(probes: .constantDenied),
                         loginItem: LoginItemCoordinator(manager: FakeLoginItem()))
    model.beginRecording(.captureRegion)
    model.handleRecordedKey(makeKeyEvent(keyCode: 40, carbon: [.command])!)
    // 先确认真的进入了待提交态，否则下面的"保持原值"会因为什么都没发生而假通过
    #expect(model.recorderMessage?.contains("⌘K") == true)
    model.handleRecordedKey(makeKeyEvent(keyCode: 53, carbon: [])!)   // Esc
    #expect(model.settings.hotkeys[.captureRegion]?.displayString == "⌃⌘A")
    #expect(!model.isRecording)
    #expect(!FileManager.default.fileExists(atPath: file.path))       // 没提交就不该写盘
}

struct FakeLoginItem: LoginItemManaging {
    private let box = Box(false)
    func isEnabled() -> Bool { box.value }
    func setEnabled(_ on: Bool) -> Result<Void, Error> { box.value = on; return .success(()) }
    final class Box: @unchecked Sendable { var value: Bool; init(_ v: Bool) { value = v } }
}
