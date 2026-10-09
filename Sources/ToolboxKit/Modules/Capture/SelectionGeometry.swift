import CoreGraphics
import Foundation

/// 截图选区与贴图窗口的所有坐标算术。
///
/// 全部是纯函数，AppKit 视图层一律不做算术 —— 多屏负坐标 + Retina + Y 轴翻转
/// 这三件事凑在一起，不放在纯函数里就根本没法测（spec §5.2）。
///
/// 坐标系约定：
/// - `points` / `screenFrame`：AppKit 全局坐标，原点在主屏**左下角**，y 向上
/// - `pixels`：某块屏自己那张 CGImage 的坐标，原点**左上角**，y 向下，已乘 scale
public enum SelectionGeometry {

    /// 两点拖拽 → 矩形。任意方向都归一成 正宽高，并钳进 bounds。
    public static func normalize(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect {
        let x0 = min(start.x, end.x), x1 = max(start.x, end.x)
        let y0 = min(start.y, end.y), y1 = max(start.y, end.y)
        var r = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        r = intersectOrClamp(r, to: bounds)
        // 原地点击也要有可裁剪的区域
        if r.width < 1 { r.size.width = 1 }
        if r.height < 1 { r.size.height = 1 }
        return r.integral
    }

    /// AppKit 全局 points → 该屏 CGImage 的像素 rect。
    /// Y 必须翻转，X 要减掉屏原点（副屏可能是负坐标）。
    public static func pointsToPixels(_ rect: CGRect, screenFrame: CGRect,
                                     scale: CGFloat) -> CGRect {
        let clamped = intersectOrClamp(rect, to: screenFrame)
        let relX = clamped.minX - screenFrame.minX
        // 选区顶边在 AppKit 里是 maxY；换算到顶原点就是 (屏高 - maxY)
        let topFromBottom = screenFrame.height - clamped.maxY
        let px = (relX * scale).rounded()
        let py = (topFromBottom * scale).rounded()
        let pw = max(1, (clamped.width * scale).rounded())
        let ph = max(1, (clamped.height * scale).rounded())
        let maxX = screenFrame.width * scale
        let maxY = screenFrame.height * scale
        return CGRect(x: min(max(0, px), max(0, maxX - pw)),
                      y: min(max(0, py), max(0, maxY - ph)),
                      width: min(pw, maxX), height: min(ph, maxY))
    }

    public static func clampZoom(_ raw: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, raw))
    }

    /// 缩放时保持中心不动（Snipaste 的行为）。
    public static func zoomedFrame(contentOrigin: CGPoint, intrinsic: CGSize,
                                   zoom: CGFloat) -> CGRect {
        let w = intrinsic.width * zoom
        let h = intrinsic.height * zoom
        let center = CGPoint(x: contentOrigin.x + intrinsic.width / 2,
                             y: contentOrigin.y + intrinsic.height / 2)
        return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }

    /// 把窗口钳回可视区。
    /// 窗口比可视区还大时**优先保证左上角可见**：
    /// 若按常规 min/max 夹，会得到 `maxX - width < minX` 的负区间，
    /// 结果是窗口整个被推到屏幕外、再也拖不回来。
    public static func clampedToScreen(_ frame: CGRect, screen: CGRect,
                                       visible: CGRect) -> CGRect {
        let area = visible.intersection(screen)
        var x = frame.minX, y = frame.minY
        if frame.width >= area.width {
            x = area.minX
        } else {
            x = Swift.max(area.minX, Swift.min(x, area.maxX - frame.width))
        }
        if frame.height >= area.height {
            y = area.minY
        } else {
            y = Swift.max(area.minY, Swift.min(y, area.maxY - frame.height))
        }
        return CGRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    /// 操作条默认贴在选区**下沿之下**（AppKit 里 y 更小）；
    /// 下方放不下就翻到选区上方，再不行就压回屏内。
    public static func stripFrame(for selection: CGRect, strip: CGSize, screen: CGRect,
                                  gap: CGFloat = 8) -> CGRect {
        var y = selection.minY - gap - strip.height
        if y < screen.minY {
            y = selection.maxY + gap
            if y + strip.height > screen.maxY {
                y = Swift.max(screen.minY, screen.maxY - strip.height)
            }
        }
        var x = selection.midX - strip.width / 2
        x = Swift.max(screen.minX, Swift.min(x, screen.maxX - strip.width))
        return CGRect(x: x.rounded(), y: y.rounded(), width: strip.width, height: strip.height)
    }

    // MARK: - 内部

    /// 完全在 bounds 外时退化成角点，避免产生零面积矩形让后续除法炸掉。
    private static func intersectOrClamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let x0 = Swift.max(bounds.minX, Swift.min(rect.minX, bounds.maxX))
        let x1 = Swift.max(bounds.minX, Swift.min(rect.maxX, bounds.maxX))
        let y0 = Swift.max(bounds.minY, Swift.min(rect.minY, bounds.maxY))
        let y1 = Swift.max(bounds.minY, Swift.min(rect.maxY, bounds.maxY))
        return CGRect(x: Swift.min(x0, x1), y: Swift.min(y0, y1),
                      width: Swift.abs(x1 - x0), height: Swift.abs(y1 - y0))
    }
}
