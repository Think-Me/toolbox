// 开发期用：把一张 PNG 放进真剪贴板，模拟"复制了一张图"。
// 用法：dev-copy-image <png 路径>
import AppKit
import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let data = try? Data(contentsOf: url) else { print("读不到文件"); exit(1) }
let pb = NSPasteboard.general
pb.clearContents()
pb.setData(data, forType: .png)
print("copied image \(data.count) bytes")
