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
        // 顶原点，好让第 0 行就是最上面那格
        ctx.translateBy(x: 0, y: CGFloat(rows)); ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        // 关键：目标尺寸用**分数** width/cell。
        // 若铺满整数 cols，CoreGraphics 会把源均匀重采样成 cols 份，
        // 每格实际覆盖 width/cols ≠ cell，渲染时格子就和取色错位了。
        ctx.draw(src, in: CGRect(x: 0, y: 0,
                                 width: rect.width / cell, height: rect.height / cell))
        guard let data = ctx.data else { return nil }
        let bytes = [UInt8](UnsafeRawBufferPointer(start: data, count: cols * rows * 4))
        return MosaicGrid(rect: rect, cellPoints: cell, columns: cols, rows: rows, bytes: bytes)
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
    public let cellPoints: CGFloat
    public let columns: Int
    public let rows: Int
    private let bytes: [UInt8]

    init(rect: CGRect, cellPoints: CGFloat, columns: Int, rows: Int, bytes: [UInt8]) {
        self.rect = rect; self.cellPoints = cellPoints
        self.columns = columns; self.rows = rows; self.bytes = bytes
    }

    /// 某 point 坐标落在哪一格
    public func cellIndex(at p: CGPoint) -> (col: Int, row: Int)? {
        guard p.x >= rect.minX, p.y >= rect.minY else { return nil }
        let col = Int((p.x - rect.minX) / cellPoints)
        let row = Int((p.y - rect.minY) / cellPoints)
        guard col < columns, row < rows else { return nil }
        return (col, row)
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
