import Testing
@testable import ToolboxKit

/// 只锁类型形状与 spec §2.1 的键位集合一致。
/// "热键到底能不能触发"不靠这里，靠 `--smoke-hotkey` + 合成 ⌃⌘A 的端到端冒烟（任务 5 Step 2）。
@Test func hotkeyIDDefaultsCoverSpec() {
    // 打开设置已按用户要求从全局热键里移除（菜单里的 ⌘, 是本地快捷键）
    #expect(HotkeyID.allCases.count == 6)
    #expect(HotkeyID.allCases.contains(.captureRegion))
    #expect(HotkeyID.allCases.contains(.clipboard))
    #expect(HotkeyID.allCases.contains(.translateSelection))
    #expect(AppSettings.default.hotkeys[.translateSelection] != nil)
    // 用 rawValue 断言：成员已经删掉，直接写 .openSettings 编译不过
    #expect(HotkeyID.allCases.allSatisfy { $0.rawValue != "openSettings" })
    #expect(HotkeyID.allCases.map(\.label).count == HotkeyID.allCases.count)
}

@Test func failureCasesAreDistinguishable() {
    #expect(HotkeyCenter.Failure.invalidCombo != .comboAlreadyBound)
    #expect(HotkeyCenter.Failure.carbon(-9878) == .carbon(-9878))
}
