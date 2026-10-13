import Foundation
import Testing
@testable import ToolboxKit

private let v = KeyCombo(keyCode: KeyCombo.ansiV, carbonModifiers: KeyCombo.cmd | KeyCombo.shift)
private let a = KeyCombo(keyCode: KeyCombo.ansiA, carbonModifiers: KeyCombo.control | KeyCombo.cmd)
private let f2 = KeyCombo(keyCode: KeyCombo.f2, carbonModifiers: 0)
private let f3 = KeyCombo(keyCode: KeyCombo.f3, carbonModifiers: 0)
private let bindings: [HotkeyID: KeyCombo] = [
    .clipboard: v, .captureRegion: a, .captureFull: f2, .killAllPins: f3,
]

@Test func conflictNamesTheOtherHotkey() {
    // 用中文名而不是 rawValue：用户看到的"已分配给「区域截图」"才有意义
    let msg = HotkeyConflict.detect(proposed: a, for: .clipboard,
                                    bindings: bindings, probeOccupied: nil)
    #expect(msg?.contains("区域截图") == true)
    #expect(msg?.contains(a.displayString) == true)
}

@Test func uniqueComboHasNoConflict() {
    let msg = HotkeyConflict.detect(proposed: KeyCombo(keyCode: KeyCombo.ansiD,
                                                       carbonModifiers: KeyCombo.control),
                                    for: .clipboard, bindings: bindings)
    #expect(msg == nil)
}

@Test func repickingOwnComboIsNotAConflictAndDoesNotProbe() {
    // 这个键位正由我们自己持有：probe 必然返回"被占用"，
    // 无脑探测就会把"重新录成同一个键位"误判成冲突
    var probed = false
    let msg = HotkeyConflict.detect(proposed: f2, for: .captureFull, bindings: bindings,
                                    probeOccupied: { _ in probed = true; return true })
    #expect(msg == nil)
    #expect(probed == false)
}

@Test func ownConflictIsReportedBeforeProbing() {
    // 自己人撞了就直接拒，省一次 Carbon 调用
    var probed = false
    let msg = HotkeyConflict.detect(proposed: f3, for: .clipboard, bindings: bindings,
                                    probeOccupied: { _ in probed = true; return true })
    #expect(msg?.contains("关闭所有贴图") == true)
    #expect(probed == false)
}

@Test func otherAppConflictIsReported() {
    let msg = HotkeyConflict.detect(proposed: KeyCombo(keyCode: KeyCombo.ansiD,
                                                       carbonModifiers: KeyCombo.control),
                                    for: .clipboard, bindings: bindings,
                                    probeOccupied: { _ in true })
    #expect(msg?.contains("其他 App") == true)
    #expect(msg?.contains("Snipaste") == true)
}

@Test func probeOnlySeesTheProposedCombo() {
    // 探测只应在"用这个键位"时被调用，而不是拿别的键位去探
    var seen: [KeyCombo] = []
    let d = KeyCombo(keyCode: KeyCombo.ansiD, carbonModifiers: KeyCombo.control)
    _ = HotkeyConflict.detect(proposed: d, for: .clipboard, bindings: bindings,
                              probeOccupied: { seen.append($0); return false })
    #expect(seen == [d])
}
