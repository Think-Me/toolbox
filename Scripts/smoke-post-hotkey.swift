// 合成一次 ⌃⌘A，验证 HotkeyCenter 的回调通路。
// 前提：**发送方**进程必须有辅助功能权限，否则 CGEvent 被静默丢弃。
// 用法：必须先用 swiftc 编译成二进制再跑；`swift xxx.swift` 解释执行会因编译耗时
//       晚于监听进程寿命而误判成"热键不工作"（探测阶段踩过）。
import Carbon.HIToolbox
import CoreGraphics

let src = CGEventSource(stateID: .combinedSessionState)
let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: true)
down?.flags = [.maskControl, .maskCommand]
down?.post(tap: .cghidEventTap)
usleep(80_000)
let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: false)
up?.flags = [.maskControl, .maskCommand]
up?.post(tap: .cghidEventTap)
print("posted ⌃⌘A")
