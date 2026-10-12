import AppKit
import Testing
@testable import ToolboxKit

/// 钉住"热键用着用着失灵"这个 bug：
/// `suspend` 之后如果没有任何一条路径调用 `resume`，全部全局热键会永久注销。
/// 现在遮罩收口 (`dismiss`) 无条件 `resumeAll`，恢复不再依赖调用者自觉。
@MainActor
private func tryRegister(_ center: HotkeyCenter, _ id: HotkeyID,
                         _ combo: KeyCombo) -> Bool {
    center.register(id, combo, handler: {}) && center.boundCombo(for: id) != nil
}

@Test
@MainActor func suspendHidesBindingAndResumeAllRestoresIt() throws {
    let center = HotkeyCenter()
    guard tryRegister(center, .killAllPins,
                      KeyCombo(keyCode: KeyCombo.f3, carbonModifiers: 0)) else {
        throw SkipError()      // 无 GUI 的环境装不上 Carbon，跳过而不是空过
    }
    center.suspend([.killAllPins])
    #expect(center.boundCombo(for: .killAllPins) == nil)
    #expect(center.suspendedIDs == [.killAllPins])

    center.resumeAll()
    #expect(center.boundCombo(for: .killAllPins) != nil)
    #expect(center.suspendedIDs.isEmpty)
}

@Test
@MainActor func resumeAllWithoutSuspendIsHarmless() {
    // dismiss() 现在无条件调用它，所以"什么都没挂起"时必须完全无害
    let center = HotkeyCenter()
    center.resumeAll()
    center.resumeAll()
    #expect(center.suspendedIDs.isEmpty)
}

@Test
@MainActor func doubleSuspendKeepsTheSnapshot() throws {
    // 第二次挂起不能把已经清掉的 bindings 存成 nil，否则永远复原不出来
    let center = HotkeyCenter()
    guard tryRegister(center, .captureRegion,
                      KeyCombo(keyCode: KeyCombo.ansiA,
                               carbonModifiers: KeyCombo.control | KeyCombo.cmd)) else {
        throw SkipError()
    }
    center.suspend([.captureRegion])
    center.suspend([.captureRegion])
    #expect(center.suspendedIDs == [.captureRegion])
    center.resumeAll()
    #expect(center.boundCombo(for: .captureRegion) != nil)
}

@Test
@MainActor func resumeOneLeavesTheOthersSuspended() throws {
    let center = HotkeyCenter()
    guard tryRegister(center, .captureRegion,
                      KeyCombo(keyCode: KeyCombo.ansiD, carbonModifiers: KeyCombo.control)),
          tryRegister(center, .captureFull,
                      KeyCombo(keyCode: KeyCombo.f2, carbonModifiers: 0)) else { throw SkipError() }
    center.suspend(HotkeyID.allCases)
    center.resume([.captureRegion])
    #expect(center.boundCombo(for: .captureRegion) != nil)
    #expect(center.boundCombo(for: .captureFull) == nil)
    center.resumeAll()
    #expect(center.boundCombo(for: .captureFull) != nil)
}

@Test
@MainActor func reRegisterWhileSuspendedWins() throws {
    // 挂起期间用户在设置里改键位：新注册必须生效，旧快照不能再把它盖回去
    let center = HotkeyCenter()
    guard tryRegister(center, .openSettings,
                      KeyCombo(keyCode: KeyCombo.comma,
                               carbonModifiers: KeyCombo.control | KeyCombo.cmd)) else {
        throw SkipError()
    }
    center.suspend([.openSettings])
    #expect(center.boundCombo(for: .openSettings) == nil)
    guard tryRegister(center, .openSettings,
                      KeyCombo(keyCode: KeyCombo.space, carbonModifiers: KeyCombo.control)) else {
        throw SkipError()
    }
    center.resumeAll()
    #expect(center.boundCombo(for: .openSettings) == KeyCombo(keyCode: KeyCombo.space,
                                                              carbonModifiers: KeyCombo.control))
}

private struct SkipError: Error {}
