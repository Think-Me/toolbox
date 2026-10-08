import Testing
@testable import ToolboxKit

@Test func rejectsBareLetter() {
    var m = HotkeyRecorderModel(initial: KeyCombo(keyCode: KeyCombo.ansiA,
                                                  carbonModifiers: KeyCombo.cmd))
    m.beginRecording()
    m.keyPressed(KeyCombo(keyCode: KeyCombo.ansiA, carbonModifiers: KeyCombo.shift))
    #expect(m.pending == nil)
    #expect(m.rejectedMessage != nil)
    #expect(m.value.displayString == "⌘A")     // 原值不许被污染
}

@Test func escapeCancelsAndKeepsOld() {
    let old = KeyCombo(keyCode: KeyCombo.ansiA, carbonModifiers: KeyCombo.cmd)
    var m = HotkeyRecorderModel(initial: old)
    m.beginRecording()
    m.keyPressed(KeyCombo(keyCode: KeyCombo.ansiV, carbonModifiers: KeyCombo.cmd | KeyCombo.option))
    #expect(m.pending != nil)
    m.escape()
    #expect(m.committed == nil)
    #expect(m.value == old)
    #expect(m.isRecording == false)
}

@Test func commitEmitsNewValue() {
    var m = HotkeyRecorderModel(initial: KeyCombo(keyCode: KeyCombo.ansiA,
                                                  carbonModifiers: KeyCombo.cmd))
    m.beginRecording()
    let next = KeyCombo(keyCode: KeyCombo.ansiV, carbonModifiers: KeyCombo.control | KeyCombo.cmd)
    m.keyPressed(next)
    #expect(m.commit() == next)
    #expect(m.value == next)
    #expect(m.isRecording == false)
}

@Test func bareFunctionKeyIsAccepted() {
    var m = HotkeyRecorderModel(initial: KeyCombo(keyCode: KeyCombo.ansiA,
                                                  carbonModifiers: KeyCombo.cmd))
    m.beginRecording()
    m.keyPressed(KeyCombo(keyCode: KeyCombo.f3, carbonModifiers: 0))
    #expect(m.pending?.displayString == "F3")
    #expect(m.rejectedMessage == nil)
}

@Test func commitWithoutPendingChangesNothing() {
    let old = KeyCombo(keyCode: KeyCombo.ansiH, carbonModifiers: KeyCombo.cmd | KeyCombo.shift)
    var m = HotkeyRecorderModel(initial: old)
    m.beginRecording()
    #expect(m.commit() == nil)
    #expect(m.value == old)
}

@Test func rejectionMessageNamesTheMissingModifiers() {
    var m = HotkeyRecorderModel(initial: KeyCombo(keyCode: KeyCombo.ansiA,
                                                  carbonModifiers: KeyCombo.cmd))
    m.beginRecording()
    m.keyPressed(KeyCombo(keyCode: KeyCombo.ansiA, carbonModifiers: 0))
    let msg = m.rejectedMessage ?? ""
    #expect(msg.contains("⌘") && msg.contains("⌥") && msg.contains("⌃"))
}
