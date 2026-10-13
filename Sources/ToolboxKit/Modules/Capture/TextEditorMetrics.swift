import AppKit
import CoreGraphics
import Foundation

/// 内联文字输入框的宽度计算。
///
/// 抽成纯函数是因为"框该多宽"这件事很容易写错成固定值：
/// 固定宽的话，输入一个字也是一大条、输入很长又会溢出选区。
public enum TextEditorMetrics {
    /// 空框时给两个字符的宽度：够看清"在这儿打字"，又不会盖住大片画面
    public static let minimumCharacters: CGFloat = 2
    /// 文字两侧留白，避免光标贴边、最后一个字被切
    public static let horizontalPadding: CGFloat = 12

    /// 文字行高。输入框高度必须用它，不能用 fontSize 的固定倍数：
    /// 框比文字高会把文字**垂直居中**，于是编辑时看到的位置和最终画出来的
    /// 位置差几 pt（渲染是按锚点顶对齐的），看起来像"字放下去了"。
    public static func lineHeight(fontSize: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        ]
        return ("Hg" as NSString).size(withAttributes: attrs).height
    }

    /// NSTextField 的 cell 会把文字往里缩一点，渲染侧没有这个缩进
    public static let cellHorizontalInset: CGFloat = 2

    /// 某个字号下一个汉字的近似宽度（系统字体半粗）
    public static func characterWidth(fontSize: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        ]
        return ("中" as NSString).size(withAttributes: attrs).width
    }

    /// 起笔锚点的左边界：保证从那里开始至少放得下最小宽度的框。
    /// 不做这件事的话，贴着选区右沿点一下就会得到一个几乎为零宽的输入框。
    public static func clampedAnchorX(_ x: CGFloat, fontSize: CGFloat,
                                      selection: CGRect) -> CGFloat {
        let floor = characterWidth(fontSize: fontSize) * minimumCharacters + horizontalPadding
        return Swift.min(x, selection.maxX - floor)
    }

    /// - Parameters:
    ///   - text: 当前内容（空串 = 刚起笔）
    ///   - anchorX: 输入框左沿（遮罩 point 坐标）
    ///   - selection: 选区矩形，用来限制"最多能长到哪儿"
    ///   - maxWidth: 绝对上限
    /// - Returns: 输入框宽度
    public static func width(for text: String, fontSize: CGFloat, anchorX: CGFloat,
                             selection: CGRect, maxWidth: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        ]
        let textWidth = text.isEmpty ? 0
            : (text as NSString).size(withAttributes: attrs).width
        let floor = characterWidth(fontSize: fontSize) * minimumCharacters + horizontalPadding
        let wanted = textWidth + horizontalPadding
        // **绝不越界优先于"至少两个字符"**：越界的话下划线会画到选区外，
        // 用户以为能写到那儿，而导出按选区裁剪又切掉 —— 比框窄一点糟糕得多。
        // 空间真不够时应该由视图把锚点往左挪（见 clampedAnchorX），不是让框顶出去。
        let avail = Swift.max(0, selection.maxX - anchorX)
        return Swift.min(Swift.max(wanted, floor), Swift.min(maxWidth, avail))
    }
}
