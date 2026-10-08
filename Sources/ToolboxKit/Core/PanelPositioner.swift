import Foundation

/// 浮层落点计算。纯函数，AppKit 视图层不做算术 —— 便于单测覆盖多屏负坐标。
/// AppKit 坐标：原点在左下，y 向上。
public enum PanelPositioner {

    /// 默认放在光标上方 `gap` 处；上方放不下就整块翻到光标下方；最后钳制进可视区。
    public static func rect(width: CGFloat, height: CGFloat, cursor: CGPoint,
                            screenFrame: CGRect, visibleFrame: CGRect,
                            gap: CGFloat = 12) -> CGRect {
        let area = visibleFrame.intersection(screenFrame)
        var x = cursor.x - width / 2
        var y = cursor.y + gap
        if y + height > area.maxY { y = cursor.y - gap - height }
        x = min(max(x, area.minX), area.maxX - width)
        y = min(max(y, area.minY), area.maxY - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }
    // FIXME(M1): 面板本身高于可用区时，上面的钳制会牺牲下沿而不是压缩高度。
    //   M0 只保证"不顶出上沿"（有单测锁住），压缩高度留给剪贴板面板真正做出来后处理。
}
