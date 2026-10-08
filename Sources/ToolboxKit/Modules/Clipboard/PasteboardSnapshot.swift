import AppKit
import Foundation

/// 从某个 `NSPasteboard` 读出来的原始材料，值类型，便于单测。
public struct PasteboardSnapshot: Sendable {
    public var types: [NSPasteboard.PasteboardType]
    public var text: String?
    public var fileURLs: [URL]
    /// PNG 或 TIFF，由读取方决定；归一化会统一成 PNG
    public var imageData: Data?
    public var pixelSize: CGSize?
    public var ownWriteMarker: String?

    public init(types: [NSPasteboard.PasteboardType], text: String?, fileURLs: [URL],
                imageData: Data?, pixelSize: CGSize?, ownWriteMarker: String? = nil) {
        self.types = types; self.text = text; self.fileURLs = fileURLs
        self.imageData = imageData; self.pixelSize = pixelSize
        self.ownWriteMarker = ownWriteMarker
    }

    /// 薄壳，不做判定。用命名 pasteboard 就能测（见 PasteboardSnapshotTests）。
    public static func read(from pb: NSPasteboard) -> PasteboardSnapshot {
        let types = pb.types ?? []
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        var imageData: Data?
        if let png = pb.data(forType: .png) {
            imageData = png
        } else if let tiff = pb.data(forType: .tiff) {
            imageData = tiff
        }
        var pixelSize: CGSize?
        if let data = imageData, let image = NSImage(data: data) {
            // 用 representation 的真实像素，不用 image.size（那是 point，Retina 下差 2 倍）
            if let rep = image.representations.first {
                pixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            }
        }
        return PasteboardSnapshot(types: types,
                                  text: pb.string(forType: .string),
                                  fileURLs: urls,
                                  imageData: imageData,
                                  pixelSize: pixelSize,
                                  ownWriteMarker: pb.string(forType: .ownWrite))
    }
}

/// 类型优先级归一化：文件 URL > 图片 > 纯文本。
/// 一次 pasteboard 变化只产出一条记录，所以必须有个明确的取舍顺序。
public enum PasteboardNormalizer {

    public static func normalize(_ s: PasteboardSnapshot) -> CapturedContent? {
        if !s.fileURLs.isEmpty {
            var seen = Set<String>()
            let unique = s.fileURLs.filter { seen.insert($0.path).inserted }
            let joined = unique.map { $0.path.replacingOccurrences(of: "\n", with: " ") }
                               .joined(separator: "  ")
            return CapturedContent(kind: .fileURLs, text: joined, pngData: nil,
                                   fileURLs: unique, pixelSize: nil,
                                   byteLength: joined.utf8.count)
        }
        if let raw = s.imageData, let png = toPNG(raw) {
            return CapturedContent(kind: .image, text: nil, pngData: png, fileURLs: [],
                                   pixelSize: s.pixelSize ?? pixelSize(of: png),
                                   byteLength: png.count)
        }
        if let text = s.text, !text.isEmpty {
            return CapturedContent(kind: .text, text: text, pngData: nil, fileURLs: [],
                                   pixelSize: nil, byteLength: text.utf8.count)
        }
        return nil
    }

    /// TIFF 统一转 PNG：内容寻址要求同一张图每次算出同一个 sha，
    /// 而 TIFF 编码里带时间戳等不稳定字段，PNG 才是可靠的选择。
    static func toPNG(_ data: Data) -> Data? {
        if data.count >= 4, Array(data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47] { return data }
        guard let image = NSImage(data: data) else { return nil }
        return image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
            .representation(using: .png, properties: [:])
    }

    static func pixelSize(of png: Data) -> CGSize? {
        guard let rep = NSBitmapImageRep(data: png) else { return nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}
