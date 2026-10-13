import AppKit
import CoreGraphics
import Foundation

extension Annotation {
    /// 文字图形**实际渲染出来的外接框**（遮罩 point 坐标，顶原点）。
    /// 不能直接用 `boundingBox`：那只含一个锚点，面积为 0，永远点不中。
    public var textRect: CGRect {
        guard let anchor = points.first else { return .zero }
        let size = textSize
        return CGRect(x: anchor.x, y: anchor.y, width: size.width, height: size.height)
    }

    public var textSize: CGSize {
        let body = text ?? ""
        guard !body.isEmpty else { return .zero }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        ]
        return (body as NSString).size(withAttributes: attrs)
    }
}

/// 点中哪个图形。用于"拖动已画好的标注"。
public enum AnnotationHitTest {
    /// 默认容差：线宽之外再给 6pt，否则 2px 的线几乎点不中
    public static let defaultTolerance: CGFloat = 6

    /// **只有文字可以拖动**。箭头/矩形/画笔/马赛克都故意不做：
    /// 箭头的命中区就是那条线（容差 8pt），想抓住长箭头中段几乎点不中，
    /// 用户实测根本触发不了；其余图形画错了撤销重画更快，
    /// 而且让它们可点会抢走"在框内拖动选区"和"在框内空白处起新图形"。
    public static let movableTools: Set<AnnotationTool> = [.text]

    /// 返回**最上面**那个可拖动的图形 id。列表末尾是后画的，所以要倒着找 ——
    /// 从底下开始找会让被盖住的图形抢走点击。
    public static func topmost(at p: CGPoint, in list: [Annotation],
                               tolerance: CGFloat = defaultTolerance) -> UUID? {
        for a in list.reversed()
        where a.isComplete && movableTools.contains(a.tool)
            && hits(a, at: p, tolerance: tolerance) {
            return a.id
        }
        return nil
    }

    public static func hits(_ a: Annotation, at p: CGPoint,
                            tolerance: CGFloat = defaultTolerance) -> Bool {
        let pad = tolerance + a.lineWidth / 2
        switch a.tool {
        case .text:
            return a.textRect.insetBy(dx: -4, dy: -4).contains(p)
        case .rect where a.filled, .mosaic:
            return a.boundingBox.insetBy(dx: -pad, dy: -pad).contains(p)
        case .rect:
            // 空心矩形只有边框能点：否则用户永远没法在框内空白处操作别的东西
            let outer = a.boundingBox.insetBy(dx: -pad, dy: -pad)
            let inner = a.boundingBox.insetBy(dx: pad, dy: pad)
            return outer.contains(p) && !inner.contains(p)
        case .arrow:
            guard a.points.count >= 2 else { return false }
            return distance(from: p, toSegment: a.points[0], a.points[1]) <= pad
        case .pen:
            guard a.points.count >= 2 else { return false }
            for i in 0..<(a.points.count - 1)
            where distance(from: p, toSegment: a.points[i], a.points[i + 1]) <= pad { return true }
            return false
        }
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = Swift.max(0, Swift.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
