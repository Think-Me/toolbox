import CoreGraphics
import Foundation

/// 标注工具的几何计算。纯函数，全部可测。
public enum AnnotationGeometry {

    /// 两点 → 正宽高矩形。四个拖拽方向必须得到同一结果，
    /// 否则"往回画"出来的选区/矩形会带负尺寸，裁剪与渲染都拿到畸形值。
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: Swift.min(a.x, b.x), y: Swift.min(a.y, b.y),
               width: Swift.abs(a.x - b.x), height: Swift.abs(a.y - b.y))
    }

    public static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 箭头头部三角形：[尖, 翼1, 翼2]
    public static func arrowHead(from: CGPoint, to: CGPoint, width: CGFloat) -> [CGPoint] {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        let headLength = Swift.max(6, width * 3)
        guard length > 0.0001 else {
            // 零长线段：给一个朝下的默认头。
            // 不能返回含 NaN 的点 —— 那会让整条路径画不出来，
            // 而且 NaN 在 CGRect 里会一路传染成 null rect，非常难查。
            let half = headLength * 0.45
            return [to,
                    CGPoint(x: to.x - half, y: to.y + headLength),
                    CGPoint(x: to.x + half, y: to.y + headLength)]
        }
        let ux = dx / length, uy = dy / length
        let base = CGPoint(x: to.x - ux * headLength, y: to.y - uy * headLength)
        let half = headLength * 0.45
        // 垂直方向
        let px = -uy, py = ux
        return [to,
                CGPoint(x: base.x + px * half, y: base.y + py * half),
                CGPoint(x: base.x - px * half, y: base.y - py * half)]
    }

    /// 画笔抽稀。
    ///
    /// 必需：触摸板慢慢拖一笔能产生上千个 mouseDragged 事件，
    /// 全存下来会让撤销栈（每步一份完整列表）和渲染都变慢。
    ///
    /// 两条保留规则缺一不可：
    /// - 距离：去掉近乎重合的点
    /// - 折角：方向突变处必须保留，否则来回画的线会被"抄近路"抹掉转折点
    public static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let t2 = tolerance * tolerance
        var out: [CGPoint] = [points[0]]
        var lastKept = points[0]
        for i in 1..<(points.count - 1) {
            let prev = points[i - 1], cur = points[i], next = points[i + 1]
            let d1 = CGVector(dx: cur.x - prev.x, dy: cur.y - prev.y)
            let d2 = CGVector(dx: next.x - cur.x, dy: next.y - cur.y)
            let n1 = (d1.dx * d1.dx + d1.dy * d1.dy).squareRoot()
            let n2 = (d2.dx * d2.dx + d2.dy * d2.dy).squareRoot()
            var sharp = false
            if n1 > 0, n2 > 0 {
                let cos = (d1.dx * d2.dx + d1.dy * d2.dy) / (n1 * n2)
                sharp = cos < 0.85
            }
            let ddx = cur.x - lastKept.x, ddy = cur.y - lastKept.y
            let far = ddx * ddx + ddy * ddy >= t2
            if sharp || far {
                out.append(cur)
                lastKept = cur
            }
        }
        out.append(points[points.count - 1])   // 端点必留，否则线会缩短
        return out
    }
}
