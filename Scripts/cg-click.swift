// 开发期 UI 自动化：在屏幕全局坐标（左上原点）合成一次鼠标点击。
// 用法：cg-click <x> <y>   —— 需要发送方有辅助功能权限。
import CoreGraphics
import Foundation

let x = Double(CommandLine.arguments[1])!, y = Double(CommandLine.arguments[2])!
let src = CGEventSource(stateID: .combinedSessionState)
CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(120_000)
CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(60_000)
CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
print("clicked \(x),\(y)")
