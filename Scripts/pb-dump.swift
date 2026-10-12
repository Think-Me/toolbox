// 开发期 UI 自动化：把通用剪贴板里的图片写到文件，用于验证"导出的图里到底有没有标注"。
// 用法：pb-dump <输出路径>
import AppKit
import Foundation

let out = CommandLine.arguments[1]
let pb = NSPasteboard.general
if let data = pb.data(forType: .tiff) ?? pb.data(forType: .png),
   let img = NSImage(data: data),
   let tiff = img.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: out))
    print("ok \(rep.pixelsWide)x\(rep.pixelsHigh) -> \(out)")
} else {
    print("no image on pasteboard; types=\(String(describing: pb.types))")
}
