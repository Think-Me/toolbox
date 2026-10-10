import CoreGraphics
import Foundation

/// 放大镜：跟随光标的像素级取景 + 光标处颜色。
///
/// 坐标系：全部是**遮罩视图的 flipped 坐标**（顶原点，y 向下）与
/// **冻结帧 CGImage 的像素坐标**（同样是顶原点）。两边都是顶原点，
/// 所以只需要乘 scale，不需要任何 Y 翻转。
public enum Magnifier {
    /// 取 15×15 源像素：奇数才能保证正中间有一个"光标所在像素"
    public static let sourcePixels = 15
    public static let outputSize: CGFloat = 120
    /// 放大镜离光标的距离（点）
    public static let cursorGap: CGFloat = 18
    /// 颜色条高度
    public static let labelHeight: CGFloat = 22

    /// 应截取的源矩形（像素）。贴边时向内收缩，绝不越界。
    public static func sourceRect(cursorInScreenPoints: CGPoint, scale: CGFloat,
                                  imageSize: CGSize) -> CGRect {
        let half = CGFloat(sourcePixels / 2)
        let px = (cursorInScreenPoints.x * scale).rounded() - half
        let py = (cursorInScreenPoints.y * scale).rounded() - half
        let side = min(CGFloat(sourcePixels), max(1, min(imageSize.width, imageSize.height)))
        let maxX = max(0, imageSize.width - side)
        let maxY = max(0, imageSize.height - side)
        return CGRect(x: Swift.max(0, Swift.min(px, maxX)),
                      y: Swift.max(0, Swift.min(py, maxY)),
                      width: side, height: side)
    }

    /// 光标像素的 HEX。越界返回 nil 而不是崩。
    public static func hexColor(of image: CGImage, pixelX: Int, pixelY: Int) -> String? {
        guard pixelX >= 0, pixelY >= 0, pixelX < image.width, pixelY < image.height
        else { return nil }
        guard let one = image.cropping(to: CGRect(x: pixelX, y: pixelY, width: 1, height: 1))
        else { return nil }
        // 画进一个已知的 RGBA8 上下文再读，比手工解析 image 自身的像素格式可靠得多
        // （位图可能是 BGRA / 带 alpha / 不同 bytesPerRow）
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }

    /// 放大镜整体位置：默认放光标右下，放不下就翻到左/上，最后钳进容器。
    public static func frame(cursor: CGPoint, container: CGRect,
                             size: CGSize) -> CGRect {
        var x = cursor.x + cursorGap
        if x + size.width > container.maxX { x = cursor.x - cursorGap - size.width }
        var y = cursor.y + cursorGap
        if y + size.height > container.maxY { y = cursor.y - cursorGap - size.height }
        x = Swift.max(container.minX, Swift.min(x, container.maxX - size.width))
        y = Swift.max(container.minY, Swift.min(y, container.maxY - size.height))
        if size.width > container.width { x = container.minX }
        if size.height > container.height { y = container.minY }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 中心十字准星相对放大镜原点的偏移（点）
    public static var crosshairOffset: CGFloat {
        CGFloat(sourcePixels / 2) * cellSize
    }

    public static var cellSize: CGFloat { outputSize / CGFloat(sourcePixels) }

    /// 尺寸标签。给用户看的是 points——Retina 下显示像素会让人觉得"框大了两倍"。
    public static func sizeLabel(pointsSize: CGSize) -> String {
        "\(Int(pointsSize.width.rounded())) × \(Int(pointsSize.height.rounded()))"
    }
}
