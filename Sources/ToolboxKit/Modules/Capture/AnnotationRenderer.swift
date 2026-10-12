import AppKit
import CoreGraphics
import Foundation

/// 把图形列表画进任意 CGContext。
///
/// **只有一条渲染路径**：预览传 scale=1（point 空间），导出传 scale=backingScale
/// （pixel 空间）。两条路径各写一份的后果是 Retina 导出线宽减半、文字发虚，
/// 而预览看起来完全正常 —— 问题只在图被存盘/粘贴出去之后才暴露。
///
/// 约定：调用方的 ctx 使用**左上原点、y 向下**的坐标（与 SelectionView 的
/// flipped 坐标一致），标注坐标可直接用。
public enum AnnotationRenderer {

    public static func render(_ annotations: [Annotation], in ctx: CGContext,
                              scale: CGFloat, origin: CGPoint = .zero,
                              mosaicSource: MosaicSource?) {
        guard !annotations.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -origin.x, y: -origin.y)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for a in annotations where a.isComplete {
            draw(a, in: ctx, mosaicSource: mosaicSource)
        }
    }

    private static func draw(_ a: Annotation, in ctx: CGContext, mosaicSource: MosaicSource?) {
        switch a.tool {
        case .rect: drawRect(a, in: ctx)
        case .arrow: drawArrow(a, in: ctx)
        case .pen: drawPen(a, in: ctx)
        case .mosaic: drawMosaic(a, in: ctx, mosaicSource: mosaicSource)
        case .text: drawText(a, in: ctx)
        }
    }

    private static func endpoints(of a: Annotation) -> (CGPoint, CGPoint)? {
        guard a.points.count >= 2 else { return nil }
        return (a.points[0], a.points[a.points.count - 1])
    }

    private static func drawRect(_ a: Annotation, in ctx: CGContext) {
        guard let (p0, p1) = endpoints(of: a) else { return }
        let rect = AnnotationGeometry.rect(from: p0, to: p1)
        if a.filled {
            ctx.setFillColor(a.color.nsColor.cgColor)
            ctx.addRect(rect)
            ctx.drawPath(using: .fill)
        } else {
            ctx.setStrokeColor(a.color.nsColor.cgColor)
            ctx.setLineWidth(a.lineWidth)
            // 内缩半个线宽，让描边正好落在拖出来的矩形边界上
            ctx.addRect(rect.insetBy(dx: a.lineWidth / 2, dy: a.lineWidth / 2))
            ctx.drawPath(using: .stroke)
        }
    }

    private static func drawArrow(_ a: Annotation, in ctx: CGContext) {
        guard let (p0, p1) = endpoints(of: a) else { return }
        ctx.setFillColor(a.color.nsColor.cgColor)
        ctx.setStrokeColor(a.color.nsColor.cgColor)
        ctx.setLineWidth(a.lineWidth)
        let head = AnnotationGeometry.arrowHead(from: p0, to: p1, width: a.lineWidth)
        // 杆只画到两翼中点，否则粗线宽会从箭头中间戳出来
        let base = CGPoint(x: (head[1].x + head[2].x) / 2, y: (head[1].y + head[2].y) / 2)
        ctx.move(to: p0)
        ctx.addLine(to: base)
        ctx.drawPath(using: .stroke)
        ctx.move(to: head[0])
        ctx.addLine(to: head[1])
        ctx.addLine(to: head[2])
        ctx.closePath()
        ctx.drawPath(using: .fill)
    }

    private static func drawPen(_ a: Annotation, in ctx: CGContext) {
        guard a.points.count >= 2 else { return }
        ctx.setStrokeColor(a.color.nsColor.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.move(to: a.points[0])
        for p in a.points.dropFirst() { ctx.addLine(to: p) }
        ctx.drawPath(using: .stroke)
    }

    private static func drawMosaic(_ a: Annotation, in ctx: CGContext,
                                   mosaicSource: MosaicSource?) {
        guard let (p0, p1) = endpoints(of: a) else { return }
        let rect = AnnotationGeometry.rect(from: p0, to: p1)
        guard let grid = mosaicSource?.grid(for: rect,
                                            cellPoints: AnnotationPalette.mosaicCellPoints) else {
            // 取不到冻结帧时画一块可见的灰斑。静默什么都不画更糟：
            // 用户以为"打了码"的图直接粘贴出去，就是泄露。
            ctx.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
            ctx.fill(rect)
            return
        }
        guard let block = grid.makeImage() else {
            ctx.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
            ctx.fill(rect)
            return
        }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        // 本上下文是 y 向下的，而格子图 row 0 = 顶部。翻一次让两者对齐；
        // 关于 rect 的中线翻转，所以 rect 本身位置不变。
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(block, in: rect)
        ctx.restoreGState()
    }

    private static func drawText(_ a: Annotation, in ctx: CGContext) {
        let body = a.text ?? ""
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let anchor = a.points.first else { return }
        let attr = NSAttributedString(string: body, attributes: [
            .font: NSFont.systemFont(ofSize: a.fontSize, weight: .semibold),
            .foregroundColor: a.color.nsColor,
        ])
        // AppKit 的字符串绘制要 NSGraphicsContext。flipped: true 表示锚点是文字
        // 外接矩形的**左上角**；传错就在这个 y 向下的 ctx 里上下颠倒（有测试守着）。
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        attr.draw(at: anchor)
    }
}
