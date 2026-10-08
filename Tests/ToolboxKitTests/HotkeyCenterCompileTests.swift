import Testing
@testable import ToolboxKit

/// 只锁类型形状与 spec §2.1 的键位集合一致。
/// "热键到底能不能触发"不靠这里，靠 `--smoke-hotkey` + 合成 ⌃⌘A 的端到端冒烟（任务 5 Step 2）。
@Test func hotkeyIDDefaultsCoverSpec() {
    #expect(HotkeyID.allCases.count == 5)
    #expect(HotkeyID.allCases.contains(.captureRegion))
    #expect(HotkeyID.allCases.contains(.clipboard))
}

@Test func failureCasesAreDistinguishable() {
    #expect(HotkeyCenter.Failure.invalidCombo != .comboAlreadyBound)
    #expect(HotkeyCenter.Failure.carbon(-9878) == .carbon(-9878))
}
