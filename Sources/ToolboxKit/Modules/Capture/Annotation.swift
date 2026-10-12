import AppKit
import CoreGraphics
import Foundation

public enum AnnotationTool: String, Codable, Sendable, CaseIterable, Equatable {
    case rect
    case arrow
    case pen
    case mosaic
    case text

    /// 该工具至少需要几个点才算"画完了"。
    /// 手抖碰一下只产生 1 个点，不该进撤销栈。
    public var minimumPointCount: Int { self == .text ? 1 : 2 }
    public var isStrokeBased: Bool { self == .pen }
}

/// RGBA 分量 0...1。
///
/// 为什么不用 NSColor：它既不是 Sendable 也不可 Codable，
/// 而图形列表要进撤销栈（跨 actor 边界）并要能序列化。
public struct AnnotationColor: Codable, Equatable, Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var opacity: Double

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        // 构造时就钳住：越界的分量会让 NSColor 直接返回 nil，
        // 表现为"标注忽然消失"，比画错颜色更难查
        self.red = Swift.min(1, Swift.max(0, red))
        self.green = Swift.min(1, Swift.max(0, green))
        self.blue = Swift.min(1, Swift.max(0, blue))
        self.opacity = Swift.min(1, Swift.max(0, opacity))
    }

    public static let pureRed = AnnotationColor(red: 1, green: 0, blue: 0)
    public static let pureGreen = AnnotationColor(red: 0, green: 1, blue: 0)
    public static let pureBlue = AnnotationColor(red: 0, green: 0, blue: 1)
    public static let pureWhite = AnnotationColor(red: 1, green: 1, blue: 1)
    public static let pureBlack = AnnotationColor(red: 0, green: 0, blue: 0)

    /// 亮度（0...1），测试与"文字描边对比度"这类判断要用
    public var luma: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green),
                blue: CGFloat(blue), alpha: CGFloat(opacity))
    }

    /// `#RRGGBB`。调色板圆点的标识，也用于测试断言。
    public var hexString: String {
        String(format: "#%02X%02X%02X",
               Int((red * 255).rounded()), Int((green * 255).rounded()),
               Int((blue * 255).rounded()))
    }
}

/// 一条标注图形。
///
/// 刻意用值类型 + 点数组，而不是 CALayer/NSBezierPath 对象：
/// 图层对象不可 Codable、不可 Equatable，而撤销栈要靠"整份列表是否相等"决定
/// 要不要压一步；更要紧的是"数据 ↔ 图层"双向同步会引入一整类 bug
/// （图层漏删、z 序错位、复用池串图）。渲染时从数据重建路径，只有一条数据通路。
///
/// 坐标系：遮罩视图的 flipped 坐标（左上原点、y 向下，单位 point）。
public struct Annotation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var tool: AnnotationTool
    /// rect/mosaic/arrow：[起点, 终点]；pen：N 个采样点；text：[锚点]
    public var points: [CGPoint]
    public var color: AnnotationColor
    public var lineWidth: CGFloat
    public var text: String?
    public var fontSize: CGFloat
    /// 仅 rect 有意义。默认 false：截图标注不该一上来就盖住底下的内容
    public var filled: Bool

    public init(id: UUID = UUID(), tool: AnnotationTool, points: [CGPoint],
                color: AnnotationColor, lineWidth: CGFloat,
                text: String? = nil, fontSize: CGFloat = AnnotationPalette.defaultFontSize,
                filled: Bool = false) {
        self.id = id; self.tool = tool; self.points = points
        self.color = color; self.lineWidth = lineWidth
        self.text = text; self.fontSize = fontSize
        self.filled = filled
    }

    /// 所有点的最小外接矩形。空列表返回 .zero 而不是崩。
    public var boundingBox: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 是否算"一次有效操作"（决定是否压进撤销栈）
    public var isComplete: Bool {
        if tool == .text {
            guard let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
            return !points.isEmpty
        }
        return points.count >= tool.minimumPointCount
    }
}

/// 固定调色板：6 色 × 3 线宽。
///
/// 不做系统取色面板：截图标注 99% 就是这几个颜色，
/// 多一次点击反而更慢。
public enum AnnotationPalette {
    /// 顺序稳定：UI 直接按这个顺序排圆点，改了用户会觉得"颜色被动过"
    public static let colors: [AnnotationColor] = [
        AnnotationColor(red: 1.00, green: 0.231, blue: 0.188),   // #FF3B30 红
        AnnotationColor(red: 1.00, green: 0.800, blue: 0.000),   // #FFCC00 黄
        AnnotationColor(red: 0.204, green: 0.780, blue: 0.349),  // #34C759 绿
        AnnotationColor(red: 0.000, green: 0.478, blue: 1.000),  // #007AFF 蓝
        AnnotationColor(red: 1.000, green: 1.000, blue: 1.000),  // #FFFFFF 白
        AnnotationColor(red: 0.110, green: 0.110, blue: 0.118),  // #1C1C1E 近黑
    ]

    /// 和 colors 一一对应，供设置页显示。
    /// 有测试钉住两者数量必须相等 —— 加了颜色忘了加名字，Picker 就会错位。
    public static let colorNames = ["红", "黄", "绿", "蓝", "白", "黑"]

    public static let lineWidths: [CGFloat] = [2, 4, 8]

    public static let defaultColor = colors[0]
    public static let defaultLineWidth: CGFloat = 4
    public static let defaultFontSize: CGFloat = 18
    public static let fontSizes: [CGFloat] = [14, 18, 26]

    /// 设置里存的 hex → 调色板里的颜色。
    /// 用户手改过 settings.json、或调色板换过版本时，
    /// 必须落到一个**工具条上真实存在**的颜色，否则会出现"没有任何圆点被选中"。
    public static func nearestColor(hex: String) -> AnnotationColor {
        colors.first { $0.hexString.caseInsensitiveCompare(hex) == .orderedSame }
            ?? defaultColor
    }

    /// 设置里存的任意数值 → 三档线宽里最近的一档
    public static func nearestLineWidth(_ raw: Double) -> CGFloat {
        let v = CGFloat(raw)
        return lineWidths.min(by: { abs($0 - v) < abs($1 - v) }) ?? defaultLineWidth
    }

    /// 马赛克格子边长（point）。再小就接近"模糊"而不是马赛克，
    /// 且分格数随面积平方增长，大选区会拖慢合成。
    public static let mosaicCellPoints: CGFloat = 12
}


/// 截图标注的默认值（来自设置页）。
/// 打包成一个结构而不是三个 provider 闭包：它们永远一起用。
public struct AnnotationDefaults: Equatable, Sendable {
    public var toolbarEnabled: Bool
    public var color: AnnotationColor
    public var lineWidth: CGFloat

    public init(toolbarEnabled: Bool = true,
                color: AnnotationColor = AnnotationPalette.defaultColor,
                lineWidth: CGFloat = AnnotationPalette.defaultLineWidth) {
        self.toolbarEnabled = toolbarEnabled
        self.color = color
        self.lineWidth = lineWidth
    }

    public static let standard = AnnotationDefaults()

    public init(settings: AppSettings) {
        self.toolbarEnabled = settings.annotationToolbarEnabled
        self.color = settings.annotationDefaultColor
        self.lineWidth = settings.annotationDefaultLineW
    }
}
