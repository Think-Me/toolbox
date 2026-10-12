import CoreGraphics
import Foundation

/// 剪贴板面板尺寸的纯计算。
///
/// 单独抽出来是因为"行数 → 高度"这件事有两处容易出错：
/// 超出屏幕的部分永远滚不到，而钳得过狠又会让窗口高度变成 0 直接消失。
public enum ClipboardPanelGeometry {
    public static let minRows = 3
    public static let maxRows = 40

    public static func clampedRows(_ raw: Int) -> Int {
        Swift.max(minRows, Swift.min(maxRows, raw))
    }

    /// 面板总高。`maxAvailable` 传屏幕可视高度。
    public static func panelHeight(rows: Int, headerHeight: CGFloat, rowHeight: CGFloat,
                                   verticalPadding: CGFloat, maxAvailable: CGFloat) -> CGFloat {
        let n = CGFloat(Swift.max(1, rows))
        let desired = headerHeight + n * rowHeight + verticalPadding
        // 至少留出一行可见：钳到 maxAvailable 时如果屏幕比"头部+一行"还小，
        // 宁可略微超出屏幕也不能给个 0 高（窗口会直接不见）
        let minimum = headerHeight + rowHeight
        return Swift.max(minimum, Swift.min(desired, maxAvailable))
    }
}
