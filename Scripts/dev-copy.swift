// 开发期用：往真剪贴板写一条文本，模拟用户复制。
// 用法：dev-copy "要复制的内容"
import AppKit
import Foundation

let pb = NSPasteboard.general
pb.clearContents()
pb.setString(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "sample \(Date())",
             forType: .string)
print("copied: \(pb.string(forType: .string) ?? "")")
