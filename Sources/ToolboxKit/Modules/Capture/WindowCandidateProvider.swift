import AppKit
import CoreGraphics
import Foundation

/// 一块屏的几何信息，**以 Quartz 坐标系表达**（顶原点、y 向下）。
///
/// 为什么要单独建这个类型：`CGWindowListCopyWindowInfo` 给的是 Quartz 全局坐标，
/// 而遮罩视图用的是"该屏自己的 flipped 坐标"。两者只差一个原点偏移 ——
/// 提前把这个偏移显式化，就不需要任何 Y 轴翻转公式（翻转公式是这类代码出错的重灾区）。
public struct ScreenGeometry: Sendable, Equatable {
    public let quartzOrigin: CGPoint
    public let size: CGSize

    public init(quartzOrigin: CGPoint, size: CGSize) {
        self.quartzOrigin = quartzOrigin
        self.size = size
    }

    /// 该屏自己的坐标空间，原点 (0,0)
    public var bounds: CGRect { CGRect(origin: .zero, size: size) }

    /// 从 AppKit frame（左下原点）换算。
    /// Quartz 的 y 从主屏顶边往下走，所以 `qy = primaryHeight - appKitFrame.maxY`。
    public init?(appKitFrame: CGRect, primaryHeight: CGFloat) {
        guard appKitFrame.width > 0, appKitFrame.height > 0, primaryHeight > 0 else { return nil }
        self.init(quartzOrigin: CGPoint(x: appKitFrame.minX,
                                        y: primaryHeight - appKitFrame.maxY),
                  size: appKitFrame.size)
    }

    /// 用当前真实屏幕构造。`NSScreen.screens[0]` 是主屏（带菜单栏、原点 0,0）。
    public static func current(from screen: NSScreen) -> ScreenGeometry? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return ScreenGeometry(appKitFrame: screen.frame, primaryHeight: primaryHeight)
    }
}

/// `CGWindowListCopyWindowInfo` 里我们关心的那几个字段。
public struct RawWindow: Sendable, Equatable {
    public let pid: Int32
    public let layer: Int32
    /// Quartz 全局坐标（顶原点）
    public let bounds: CGRect

    public init(pid: Int32, layer: Int32, bounds: CGRect) {
        self.pid = pid; self.layer = layer; self.bounds = bounds
    }
}

/// 纯函数过滤：这是窗口枚举里唯一可测的部分，CGWindowList 调用本身只是薄壳。
public enum WindowFilter {
    /// 只有 0 层是普通窗口。菜单栏(25)、我们的浮层/贴图(101/3)、
    /// Dock(20)、桌面(-100) 都不该被当成"可框选的窗口"。
    public static let normalWindowLayer: Int32 = 0

    /// 输入顺序即"从前到后"（CGWindowList 就是这个顺序），输出保持之。
    public static func candidateRects(_ raw: [RawWindow], screen: ScreenGeometry,
                                      ownPID: Int32) -> [CGRect] {
        let bounds = screen.bounds
        var out: [CGRect] = []
        out.reserveCapacity(raw.count)
        for w in raw {
            guard w.pid != ownPID else { continue }
            guard w.layer == normalWindowLayer else { continue }
            guard w.bounds.width > 0, w.bounds.height > 0 else { continue }
            let local = w.bounds.offsetBy(dx: -screen.quartzOrigin.x,
                                          dy: -screen.quartzOrigin.y)
            // 跨屏窗口只保留落在本屏内的部分：整块跨屏的选区没法在本屏里表达
            let clipped = local.intersection(bounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }
            out.append(clipped)
        }
        return out
    }
}

public protocol WindowCandidateProviding: Sendable {
    /// 按"从前到后"返回本屏上可框选的窗口矩形（本屏 flipped 坐标）
    func candidates(for screen: ScreenGeometry, excluding ownPID: Int32) -> [CGRect]
}

/// 真实现。
///
/// 注意：查询进程自己要有屏幕录制权限，否则 macOS 会过滤掉其它 App 的窗口，
/// 表现为"高亮时有时无"（M2 实测踩过这个坑）。
public struct CGWindowCandidateProvider: WindowCandidateProviding {
    public init() {}

    public func candidates(for screen: ScreenGeometry, excluding ownPID: Int32) -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let raw = list.compactMap(Self.rawWindow(from:))
        return WindowFilter.candidateRects(raw, screen: screen, ownPID: ownPID)
    }

    static func rawWindow(from info: [String: Any]) -> RawWindow? {
        guard let pid = info[kCGWindowOwnerPID as String] as? Int,
              let layer = info[kCGWindowLayer as String] as? Int,
              let box = info[kCGWindowBounds as String] as? [String: Any],
              let x = box["X"] as? Double, let y = box["Y"] as? Double,
              let w = box["Width"] as? Double, let h = box["Height"] as? Double
        else { return nil }
        return RawWindow(pid: Int32(pid), layer: Int32(layer),
                         bounds: CGRect(x: x, y: y, width: w, height: h))
    }
}
