import CoreGraphics
import Foundation

/// 冻结帧 + 选区 + 标注 → 一张像素图。复制/钉图/存盘都从这里出。
public enum AnnotationCompositor {

    /// - Parameters:
    ///   - frozen: 按下快捷键瞬间冻结的整屏图（**像素**尺寸）
    ///   - pixelRect: 选区在 frozen 里的像素矩形
    ///   - annotations: 标注，坐标是遮罩的 **point** 值（屏幕逻辑点，非像素）
    ///   - scale: point → 像素 的倍率（Retina 为 2）
    ///   - selectionOrigin: 选区左上角（point），用于把标注坐标平移到选区局部
    public static func compose(frozen: CGImage, pixelRect: CGRect,
                               annotations: [Annotation], scale: CGFloat,
                               selectionOrigin: CGPoint) -> CGImage? {
        guard let base = ImageCodec.crop(frozen, pixelRect: pixelRect) else { return nil }
        let effective = annotations.filter(\.isComplete)
        guard !effective.isEmpty else { return base }

        let w = base.width, h = base.height
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return base }

        // 底图先用上下文**原生**的 y-up 方向画：此时图像顶行落在 rect.maxY，
        // 正好是位图的第一行。若先翻转到 y-down 再 draw，图就上下镜像了。
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .none

        // 之后切到顶原点（y 向下），与遮罩视图/标注坐标系一致
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        let source = MosaicSource(image: frozen, scale: scale)
        AnnotationRenderer.render(effective, in: ctx, scale: scale,
                                  origin: selectionOrigin, mosaicSource: source)
        return ctx.makeImage() ?? base
    }
}
