import CoreGraphics
import Foundation

/// 一张贴图的数值状态：缩放、透明度、旋转。
///
/// 抽成纯模型的原因：滚轮、捏合、键盘步进三种输入必须动**同一个** zoom，
/// 各自维护一份就会互相"看不见"对方的结果（spec §5.4）。
/// 窗口和手势只是这个模型的视图，所以这些规则全部可单测。
public struct PinZoomModel: Equatable {

    /// 每次 `+`/`-` 的倍率
    public static let stepFactor: CGFloat = 1.25
    /// 低于这个不透明度，贴图就变成"看不见但还在占位"，比不显示更糟
    public static let minOpacity: CGFloat = 0.3
    /// 滚轮增量 → 倍率的对数系数。累乘而不是累加：
    /// 累加会让触摸板的小步长几乎不动、鼠标滚轮的大步长又一下飞掉。
    public static let scrollSensitivity: CGFloat = 0.02

    public private(set) var intrinsic: CGSize
    public var zoom: CGFloat {
        didSet { zoom = Self.clamp(zoom, min: minZoom, max: maxZoom) }
    }
    public var minZoom: CGFloat
    public var maxZoom: CGFloat
    public private(set) var opacity: CGFloat
    public private(set) var rotationDegrees: Int

    public init(intrinsic: CGSize, zoom: CGFloat = 1, minZoom: CGFloat = 0.2,
                maxZoom: CGFloat = 8, opacity: CGFloat = 1, rotationDegrees: Int = 0) {
        // 零尺寸原图（截图失败、坏数据）不能让它算出 NaN/inf，
        // 否则窗口 frame 变成非有限值后 AppKit 会直接不画，表现为"贴图消失"
        let safe = (intrinsic.width > 0 && intrinsic.width.isFinite
                    && intrinsic.height > 0 && intrinsic.height.isFinite)
            ? intrinsic : CGSize(width: 1, height: 1)
        self.intrinsic = safe
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.zoom = Self.clamp(zoom, min: minZoom, max: maxZoom)
        self.opacity = Self.clamp(opacity, min: Self.minOpacity, max: 1)
        self.rotationDegrees = rotationDegrees
    }

    public var contentSize: CGSize {
        CGSize(width: intrinsic.width * zoom, height: intrinsic.height * zoom)
    }

    /// 放大到看清单像素、缩到极小时都要最近邻；中间区间用高质量插值。
    public var usesNearestNeighbor: Bool { zoom >= 2 || zoom <= 0.5 }

    // MARK: 缩放

    /// `delta` 是滚动量（触摸板为精确增量，正数=双指上滑），
    /// `magnifySign` 由设置决定：+1 上滑放大，-1 上滑缩小。
    public mutating func apply(delta: CGFloat, magnifySign: CGFloat) {
        guard delta != 0 else { return }
        zoom = Self.clamp(zoom * exp(delta * Self.scrollSensitivity * magnifySign),
                          min: minZoom, max: maxZoom)
    }

    /// 捏合手势。Apple 文档明确 `event.magnification` 是
    /// "change in magnification，应加到当前缩放值上"，所以是加法不是乘法。
    public mutating func applyMagnificationDelta(_ delta: CGFloat) {
        guard delta != 0 else { return }
        zoom = Self.clamp(zoom + delta, min: minZoom, max: maxZoom)
    }

    public mutating func step(by direction: Int) {
        let factor = direction >= 0 ? Self.stepFactor : 1 / Self.stepFactor
        zoom = Self.clamp(zoom * factor, min: minZoom, max: maxZoom)
    }

    public mutating func reset() { zoom = 1 }

    // MARK: 透明度 / 旋转

    public mutating func adjustOpacity(by delta: CGFloat) {
        opacity = Self.clamp(opacity + delta, min: Self.minOpacity, max: 1)
    }

    /// 旋转 90°：宽高必须交换，否则旋转后图像被压扁或裁掉。
    public mutating func rotate90() {
        intrinsic = CGSize(width: intrinsic.height, height: intrinsic.width)
        rotationDegrees = (rotationDegrees + 90) % 360
    }

    private static func clamp(_ v: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        guard v.isFinite else { return min }
        return Swift.max(min, Swift.min(max, v))
    }
}
