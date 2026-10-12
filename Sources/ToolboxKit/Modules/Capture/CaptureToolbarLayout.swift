import CoreGraphics
import Foundation

/// 标注工具条 + 操作条 = **同一行**。
///
/// 单独抽成纯几何（而不是写在 NSView 里）的原因：这条布局只有"两块并排、
/// 整体居中、放不下时翻到选区上方、贴边时整行被推回屏内"四件事，
/// 而每一件事都可能出错，用截图肉眼看很容易看漏（比如只有右半边越界）。
public struct CaptureToolbarLayout: Equatable {
    public static let rowHeight: CGFloat = 32
    /// 两块面板之间的缝隙
    public static let groupGap: CGFloat = 5

    public let annotationBar: CGRect
    public let actionBar: CGRect

    public static func layout(annotationWidth: CGFloat, actionWidth: CGFloat,
                              selection: CGRect, container: CGRect) -> CaptureToolbarLayout {
        // 复用 stripFrame：它已经处理了"下方放不下就翻上方 + 钳进容器"
        let total = annotationWidth + groupGap + actionWidth
        let row = SelectionGeometry.stripFrame(for: selection,
                                               strip: CGSize(width: total, height: rowHeight),
                                               container: container)
        let bar = CGRect(x: row.minX, y: row.minY, width: annotationWidth, height: row.height)
        let act = CGRect(x: row.minX + annotationWidth + groupGap, y: row.minY,
                         width: actionWidth, height: row.height)
        return CaptureToolbarLayout(annotationBar: bar, actionBar: act)
    }
}
