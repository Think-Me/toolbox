// 开发期 UI 自动化：合成一串 ASCII 输入。用法：cg-type <文本>
// 注意：Secure Input 开启时（RustDesk 等）这些事件会被 HID 层整体丢弃。
import Carbon.HIToolbox
import CoreGraphics
import Foundation

let text = Array(CommandLine.arguments[1].uppercased())
let map: [Character: UInt16] = [
    "A": UInt16(kVK_ANSI_A), "B": UInt16(kVK_ANSI_B), "C": UInt16(kVK_ANSI_C),
    "D": UInt16(kVK_ANSI_D), "E": UInt16(kVK_ANSI_E), "F": UInt16(kVK_ANSI_F),
    "G": UInt16(kVK_ANSI_G), "H": UInt16(kVK_ANSI_H), "I": UInt16(kVK_ANSI_I),
    "J": UInt16(kVK_ANSI_J), "K": UInt16(kVK_ANSI_K), "L": UInt16(kVK_ANSI_L),
    "M": UInt16(kVK_ANSI_M), "N": UInt16(kVK_ANSI_N), "O": UInt16(kVK_ANSI_O),
    "P": UInt16(kVK_ANSI_P), "Q": UInt16(kVK_ANSI_Q), "R": UInt16(kVK_ANSI_R),
    "S": UInt16(kVK_ANSI_S), "T": UInt16(kVK_ANSI_T), "U": UInt16(kVK_ANSI_U),
    "V": UInt16(kVK_ANSI_V), "W": UInt16(kVK_ANSI_W), "X": UInt16(kVK_ANSI_X),
    "Y": UInt16(kVK_ANSI_Y), "Z": UInt16(kVK_ANSI_Z),
    " ": UInt16(kVK_Space), "0": UInt16(kVK_ANSI_0), "1": UInt16(kVK_ANSI_1),
    "2": UInt16(kVK_ANSI_2), "3": UInt16(kVK_ANSI_3), "4": UInt16(kVK_ANSI_4),
    "\n": UInt16(kVK_Return), "\t": UInt16(kVK_Tab),
]
let src = CGEventSource(stateID: .combinedSessionState)
for ch in text {
    guard let code = map[ch] else { continue }
    let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)!
    let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)!
    down.post(tap: .cghidEventTap); usleep(35_000)
    up.post(tap: .cghidEventTap); usleep(35_000)
}
print("typed \(String(text))")
