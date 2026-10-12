import CoreGraphics
import Foundation

/// 马赛克的数据来源：**截图瞬间冻结的那一帧**，不是实时屏幕内容。
///
/// 必须冻结：如果从屏幕实时取像素，选区下方若有动画/光标移动，
/// 打码内容会跟着变，甚至可能把"打码后才出现"的内容拍进去。
public struct MosaicSource: Sendable {
    public let image: CGImage
    /// point → image 像素 的倍率（Retina 为 2）
    public let scale: CGFloat

    public init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale > 0 ? scale : 1
    }

    /// 遮罩坐标(points) → 图像像素矩形，并钳在图像范围内。
    /// 不钳的话越界 crop 直接返回 nil，表现为"马赛克偶尔整块消失"。
    public func pixelRect(of rect: CGRect) -> CGRect {
        let s = scale
        let raw = CGRect(x: rect.minX * s, y: rect.minY * s,
                         width: rect.width * s, height: rect.height * s)
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let minX = Swift.max(0, Swift.min(w, raw.minX))
        let minY = Swift.max(0, Swift.min(h, raw.minY))
        let maxX = Swift.max(minX, Swift.min(w, raw.maxX))
        let maxY = Swift.max(minY, Swift.min(h, raw.maxY))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 预先把区域按 cell 分格做均值缩放。
    ///
    /// 不能逐格 crop+draw 取色：大选区（整屏 1440×900 / 12pt ≈ 9000 格）
    /// 会产生 9000 次位图绘制，肉眼可感地卡。
    /// 这里一次缩放得到 cols×rows 的均值图，之后每格只读 4 个字节。
    public func grid(for rect: CGRect, cellPoints: CGFloat) -> MosaicGrid? {
        guard rect.width > 0, rect.height > 0, cellPoints > 0 else { return nil }
        let cell = Swift.max(1, cellPoints)
        let cols = Swift.max(1, Int((rect.width / cell).rounded(.up)))
        let rows = Swift.max(1, Int((rect.height / cell).rounded(.up)))
        guard let src = pixelCrop(of: rect) else { return nil }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8,
                                  bytesPerRow: cols * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        // 铺满整个 cols×rows 上下文，且**不要**翻转：
        // y-up 下 draw 会把图像顶行放到 rect.maxY，也就是位图的 memory row 0，
        // 于是"grid 的第 0 行 = 区域顶部"自然成立。
        // 之前先 scaleBy(1,-1) 再 draw 就把格子整体上下翻了 —— 在渐变背景上
        // 表现为"马赛克比周围浅"，而且自洽的测试全都发现不了。
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: CGFloat(cols), height: CGFloat(rows)))
        guard let data = ctx.data else { return nil }
        let bytes = [UInt8](UnsafeRawBufferPointer(start: data, count: cols * rows * 4))
        // 有效格子尺寸：区域不能整除时让每格略小于目标值，
        // 好让格子严丝合缝铺满选区。留一条没打码的窄边就是泄露。
        return MosaicGrid(rect: rect, cellSize: CGSize(width: rect.width / CGFloat(cols),
                                                       height: rect.height / CGFloat(rows)),
                          columns: cols, rows: rows, bytes: bytes)
    }

    private func pixelCrop(of rect: CGRect) -> CGImage? {
        let r = pixelRect(of: rect)
        guard r.width >= 1, r.height >= 1 else { return nil }
        return image.cropping(to: r)
    }
}

/// 分格后的均值颜色图。索引从左上角开始。
public struct MosaicGrid: Sendable {
    public let rect: CGRect
    /// 有效格子尺寸（宽/高可不同；区域不整除时略小于请求值）
    public let cellSize: CGSize
    public let columns: Int
    public let rows: Int
    private let bytes: [UInt8]

    init(rect: CGRect, cellSize: CGSize, columns: Int, rows: Int, bytes: [UInt8]) {
        self.rect = rect; self.cellSize = cellSize
        self.columns = columns; self.rows = rows; self.bytes = bytes
    }

    /// 格子图（memory row 0 = 区域顶部）。
    /// 渲染时**整张最近邻放大**一次画出，而不是逐格 fill：
    /// 区域不能整除时格子是分数尺寸，逐格 fill 会在每格边界留下 1px 抗锯齿
    /// 半透明缝（实测同一片马赛克里冒出 600+ 种颜色），关掉抗锯齿又会留下
    /// 1px 谁都没填的缝 —— 那 1px 就是没打码的原图。
    public func makeImage() -> CGImage? {
        // 必须用 CFData 版：`CGDataProvider(dataInfo:data:bytes…) ` 传 Swift 数组时
        // 指针只在那次调用期间有效，provider 又不持有内存，之后 draw 读到的是
        // 悬垂指针（实测表现为"马赛克画了但看不见"，而单测可能假通过）
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: columns * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    public func color(col: Int, row: Int) -> AnnotationColor? {
        guard col >= 0, row >= 0, col < columns, row < rows else { return nil }
        let i = (row * columns + col) * 4
        guard i + 3 < bytes.count else { return nil }
        let a = CGFloat(bytes[i + 3]) / 255
        // premultipliedLast 存的是已乘 alpha 的值，这里 alpha 恒为 1，
        // 但仍除一下，免得将来接透明源图时颜色整体偏暗
        guard a > 0 else { return AnnotationColor(red: 0, green: 0, blue: 0, opacity: 0) }
        return AnnotationColor(red: CGFloat(bytes[i]) / 255 / a,
                               green: CGFloat(bytes[i + 1]) / 255 / a,
                               blue: CGFloat(bytes[i + 2]) / 255 / a, opacity: a)
    }
}
