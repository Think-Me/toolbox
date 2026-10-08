import Testing
import AppKit
@testable import ToolboxKit

@Test func displayOrderIsControlOptionShiftCommand() {
    let c = KeyCombo(keyCode: KeyCombo.ansiA,
                     carbonModifiers: KeyCombo.control | KeyCombo.option
                                    | KeyCombo.shift | KeyCombo.cmd)
    #expect(c.displayString == "⌃⌥⇧⌘A")
}

@Test func bareLetterIsInvalidWithoutModifier() {
    #expect(KeyCombo(keyCode: KeyCombo.ansiA, carbonModifiers: 0).isValidBinding == false)
}

@Test func functionKeyWithoutModifierIsValid() {
    #expect(KeyCombo(keyCode: KeyCombo.f1, carbonModifiers: 0).isValidBinding == true)
}

@Test func arrowKeyWithoutModifierIsValid() {
    #expect(KeyCombo(keyCode: 123, carbonModifiers: 0).isValidBinding == true)
}

@Test func shiftAloneIsInvalid() {
    // 只按 shift 不构成可用快捷键；shift 不能单独满足 requiredMask
    #expect(KeyCombo(keyCode: KeyCombo.ansiA, carbonModifiers: KeyCombo.shift).isValidBinding == false)
}

@Test func nseventModifierMappingIgnoresDeviceFlags() {
    let flags: NSEvent.ModifierFlags = [.command, .shift, .capsLock, .function]
    let c = KeyCombo(keyCode: KeyCombo.ansiV, modifierFlags: flags)
    #expect(c.carbonModifiers == (KeyCombo.cmd | KeyCombo.shift))
    #expect(c.displayString == "⇧⌘V")
}

@Test func keyCodeLabels() {
    #expect(KeyCombo(keyCode: KeyCombo.space, carbonModifiers: KeyCombo.cmd).displayString == "⌘Space")
    #expect(KeyCombo(keyCode: KeyCombo.deleteLeft, carbonModifiers: KeyCombo.cmd).displayString == "⌘⌫")
    #expect(KeyCombo(keyCode: 0xFEFE, carbonModifiers: 0).displayString.hasPrefix("?"))
}

@Test func codableRoundTrip() throws {
    let c = KeyCombo(keyCode: KeyCombo.ansiH, carbonModifiers: KeyCombo.cmd | KeyCombo.shift)
    let data = try JSONEncoder().encode(c)
    #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == c)
}
