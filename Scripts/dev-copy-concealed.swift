// 模拟 1Password / Bitwarden 复制密码：除了文本还打 ConcealedType 标记。
// 用来端到端验证"密码绝不进历史"这条安全底线。
import AppKit
import Foundation

let pb = NSPasteboard.general
pb.clearContents()
pb.setString(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "hunter2-secret",
             forType: .string)
pb.setString("yes", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
print("copied with ConcealedType")
