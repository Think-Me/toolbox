// 开发期 UI 自动化：合成一次真实拖拽（按下 → 分步移动 → 抬起）。
// 用法：cg-drag <x1> <y1> <x2> <y2> [步数]   —— 全局坐标，左上原点。
// 需要发送方有辅助功能权限；键盘合成会被 Secure Input 丢弃，鼠标不会。
import CoreGraphics
import Foundation

let a = CGPoint(x: Double(CommandLine.arguments[1])!, y: Double(CommandLine.arguments[2])!)
let b = CGPoint(x: Double(CommandLine.arguments[3])!, y: Double(CommandLine.arguments[4])!)
let steps = CommandLine.arguments.count > 5 ? max(2, Int(CommandLine.arguments[5]) ?? 12) : 12
let src = CGEventSource(stateID: .combinedSessionState)
func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}
post(.mouseMoved, a); usleep(150_000)
post(.leftMouseDown, a); usleep(80_000)
for i in 1...steps {
    let t = Double(i) / Double(steps)
    post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
    usleep(16_000)
}
post(.leftMouseUp, b)
print("dragged \(a) → \(b) in \(steps) steps")
