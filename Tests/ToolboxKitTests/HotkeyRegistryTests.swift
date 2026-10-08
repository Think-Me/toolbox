import Testing
@testable import ToolboxKit

@Test func assignsMonotonicIDs() {
    var r = HotkeyRegistry()
    #expect(r.insert(KeyCombo(keyCode: 0, carbonModifiers: 1)) == 1)
    #expect(r.insert(KeyCombo(keyCode: 1, carbonModifiers: 1)) == 2)
    #expect(r.count == 2)
}

@Test func duplicateComboIsRejected() {
    var r = HotkeyRegistry()
    let c = KeyCombo(keyCode: 0, carbonModifiers: 3)
    #expect(r.insert(c) != nil)
    #expect(r.insert(c) == nil)          // 同一 combo 不允许占两个 id
}

@Test func removalKeepsComboFreeAgain() {
    var r = HotkeyRegistry()
    let a = KeyCombo(keyCode: 0, carbonModifiers: 3)
    let b = KeyCombo(keyCode: 1, carbonModifiers: 3)
    guard let idA = r.insert(a) else { Issue.record("首次 insert 必须成功"); return }
    #expect(r.insert(b) != nil)
    r.remove(idA)
    #expect(r.combo(for: idA) == nil)
    #expect(r.insert(a) != nil)          // 释放后可重新注册同一 combo
}

@Test func lookupByComboFindsID() {
    var r = HotkeyRegistry()
    let c = KeyCombo(keyCode: 9, carbonModifiers: KeyCombo.cmd)
    let id = r.insert(c)
    #expect(id != nil)
    #expect(r.id(for: c) == id)
}

@Test func handlerLookupFollowsLifecycle() {
    var r = HotkeyRegistry()
    guard let id = r.insert(KeyCombo(keyCode: 3, carbonModifiers: 1), {}) else {
        Issue.record("insert 应成功"); return
    }
    #expect(r.handler(for: id) != nil)
    r.remove(id)
    #expect(r.handler(for: id) == nil)   // 注销后不得还能查到旧 handler
}
// 注：这里故意不调用 handler。`@MainActor () -> Void` 在 Swift 6 下隐式 @Sendable，
// 捕获可变局部变量会被编译器拒掉；"回调是否真被触发"由任务 5 的 --smoke-hotkey 端到端证明。
