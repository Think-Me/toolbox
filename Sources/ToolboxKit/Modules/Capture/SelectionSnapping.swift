import CoreGraphics
import Foundation

public enum SnapEdge: Hashable, Sendable {
    case left, right, top, bottom
}

/// 吸附线集合。**坐标系是遮罩视图的 flipped 坐标**（左上原点、y 向下），
/// 别和 AppKit 全局坐标混用——那是另一套（左下原点）。
public struct SnapTargets: Equatable, Sendable {
    public var xs: [CGFloat]        // 竖直吸附线（吸左右边）
    public var ys: [CGFloat]        // 水平吸附线（吸上下边）

    public init(xs: [CGFloat], ys: [CGFloat]) {
        self.xs = xs; self.ys = ys
    }

    public static let empty = SnapTargets(xs: [], ys: [])
}

public struct SnappedRect: Equatable, Sendable {
    public var rect: CGRect
    public var snappedEdges: Set<SnapEdge>
}

/// 选区边缘吸附。
public enum SelectionSnapping {
    /// 6pt：再小就吸不上（手感"咬合"不明显），再大则难以拖出精确的小区域
    public static let defaultTolerance: CGFloat = 6
    /// 吸附后仍要保证的最小尺寸，防止两条对边互吸成零宽/负宽
    public static let minSize: CGFloat = 1

    public static func targets(windows: [CGRect], screen: CGRect) -> SnapTargets {
        var xs: [CGFloat] = [screen.minX, screen.maxX]
        var ys: [CGFloat] = [screen.minY, screen.maxY]
        for w in windows {
            // 完全在屏外的窗口 intersection 会得到 null rect，自然被跳过；
            // 跨屏窗口只取落在本屏内的那部分边界
            let clipped = w.intersection(screen)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }
            xs.append(clipped.minX); xs.append(clipped.maxX)
            ys.append(clipped.minY); ys.append(clipped.maxY)
        }
        return SnapTargets(xs: Array(Set(xs)).sorted(), ys: Array(Set(ys)).sorted())
    }

    public static func snap(_ rect: CGRect, to t: SnapTargets,
                            tolerance: CGFloat = defaultTolerance) -> SnappedRect {
        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY
        var edges: Set<SnapEdge> = []

        // 左右/上下分别处理，且后一条边要用**已更新**的前一条边做守卫：
        // 否则两边界互吸可能把选区吸成负宽，后续裁剪与贴图会拿到畸形矩形。
        if let x = nearest(t.xs, to: minX, tolerance: tolerance), x <= maxX - minSize {
            minX = x; edges.insert(.left)
        }
        if let x = nearest(t.xs, to: maxX, tolerance: tolerance), x >= minX + minSize {
            maxX = x; edges.insert(.right)
        }
        if let y = nearest(t.ys, to: minY, tolerance: tolerance), y <= maxY - minSize {
            minY = y; edges.insert(.top)
        }
        if let y = nearest(t.ys, to: maxY, tolerance: tolerance), y >= minY + minSize {
            maxY = y; edges.insert(.bottom)
        }

        var out = CGRect(x: Swift.min(minX, maxX), y: Swift.min(minY, maxY),
                         width: Swift.abs(maxX - minX), height: Swift.abs(maxY - minY))
        if out.width < minSize { out.size.width = minSize }
        if out.height < minSize { out.size.height = minSize }
        return SnappedRect(rect: out, snappedEdges: edges)
    }

    /// 悬停命中：候选必须按"从前到后"传入，返回第一个包含该点的。
    public static func topmostWindow(containing point: CGPoint,
                                     in ordered: [CGRect]) -> CGRect? {
        ordered.first { $0.width > 0 && $0.height > 0 && $0.contains(point) }
    }

    /// 等距时取较小值，保证结果确定（否则同一坐标两次算可能吸到不同线上）。
    private static func nearest(_ values: [CGFloat], to v: CGFloat,
                                tolerance: CGFloat) -> CGFloat? {
        var best: CGFloat?
        var bestDist: CGFloat = .greatestFiniteMagnitude
        for candidate in values {
            let d = abs(candidate - v)
            guard d <= tolerance else { continue }
            if d < bestDist || (d == bestDist && candidate < (best ?? .greatestFiniteMagnitude)) {
                best = candidate
                bestDist = d
            }
        }
        return best
    }
}
