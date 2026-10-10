import CoreGraphics
import Foundation

public enum SelectionPhase: Equatable, Sendable {
    case idle
    case dragging
    case hasSelection
    /// 已成型后拖把手
    case resizing
}

public enum Handle: Equatable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case inside, outside
}

/// 选区交互状态。坐标一律是**遮罩视图自己的 flipped 坐标**（左上原点、y 向下），
/// 这样 "topLeft" 就是字面意思，不用在每个分支里再翻一次 Y。
public struct SelectionState: Equatable {
    public var phase: SelectionPhase = .idle
    public var rect: CGRect?
    public var dragStart: CGPoint?
    public var activeHandle: Handle?
    public var exitRequested = false
    /// 按下时光标下的窗口。拖拽位移超过 `dragToFreeThreshold` 就放弃它，
    /// 改为自由矩形——这就是 Snipaste "单击整窗、拖动自由框"的区分方式。
    public var pendingWindow: CGRect?
    public static let dragToFreeThreshold: CGFloat = 4

    public init() {}

    public var canCommit: Bool {
        guard phase == .hasSelection, let r = rect else { return false }
        return r.width >= 1 && r.height >= 1
    }
}

public enum SelectionAction: Equatable {
    /// 按下。`hover` 是光标下那个可整选的窗口（idle 时才有意义）。
    /// 不能一按下就整窗选中：那样用户就没法从窗口内部起笔框自由矩形了。
    case mouseDown(CGPoint, hover: CGRect? = nil)
    /// 明确整窗选中（用于键盘/程序触发）
    case selectWindow(CGRect)
    case mouseDragged(CGPoint)
    case mouseUp
    case escape
    /// 方向键：移动 1px
    case nudge(dx: CGFloat, dy: CGFloat)
    /// ⇧+方向键：按当前把手缩放
    case resizeNudge(dx: CGFloat, dy: CGFloat)
}

public enum SelectionReducer {
    public static let handleTolerance: CGFloat = 6

    /// `snap` 非空时对拖拽结果做边缘吸附。
    /// 只在拖拽/缩放时生效：方向键微调是像素级操作，吸附会和它打架。
    public static func reduce(_ state: SelectionState, _ action: SelectionAction,
                              bounds: CGRect, snap: SnapTargets? = nil) -> SelectionState {
        var s = state
        switch action {
        case .selectWindow(let window):
            let clipped = window.intersection(bounds)
            guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return s }
            s.phase = .hasSelection
            s.rect = clipped
            s.dragStart = nil
            s.activeHandle = nil

        case .mouseDown(let p, let hover):
            handleDown(&s, at: p, hover: hover, bounds: bounds)

        case .mouseDragged(let p):
            switch s.phase {
            case .idle:
                break
            case .dragging:
                guard let start = s.dragStart else { return s }
                // 按下时带了候选窗口，但位移很小 → 保持整窗（"单击整窗"）
                if let pending = s.pendingWindow,
                   hypot(p.x - start.x, p.y - start.y) < SelectionState.dragToFreeThreshold {
                    s.rect = pending
                    break
                }
                // 位移够大 → 放弃整窗，改自由矩形（否则用户根本框不了局部区域）
                s.pendingWindow = nil
                var r = SelectionGeometry.normalize(from: start, to: p, in: bounds)
                if let snap { r = SelectionSnapping.snap(r, to: snap).rect }
                s.rect = r
            case .hasSelection, .resizing:
                guard let start = s.dragStart, var r = s.rect, let h = s.activeHandle else { return s }
                r = resize(r, handle: h, from: start, to: p, bounds: bounds)
                if let snap { r = SelectionSnapping.snap(r, to: snap).rect }
                s.rect = r
                s.phase = .resizing
            }

        case .mouseUp:
            if s.phase == .dragging {
                s.phase = .hasSelection
                s.activeHandle = nil
                s.dragStart = nil
                s.pendingWindow = nil
            } else if s.phase == .resizing {
                s.phase = .hasSelection
                s.activeHandle = nil
                s.dragStart = nil
            }

        case .escape:
            // 两段式：有选区先清选区，没选区才退出截图
            if s.rect != nil || s.phase != .idle {
                s.rect = nil
                s.dragStart = nil
                s.activeHandle = nil
                s.phase = .idle
            } else {
                s.exitRequested = true
            }

        case .nudge(let dx, let dy):
            guard var r = s.rect else { return s }
            r.origin.x += dx
            r.origin.y += dy
            // 移动时整块平移，越界就贴边，尺寸不变
            if r.minX < bounds.minX { r.origin.x = bounds.minX }
            if r.minY < bounds.minY { r.origin.y = bounds.minY }
            if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
            if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
            s.rect = r

        case .resizeNudge(let dx, let dy):
            guard let r = s.rect else { return s }
            // `??` 之后已经是非可选，不能再写 let 绑定
            let h = s.activeHandle ?? Self.defaultHandle(for: r)
            s.activeHandle = h
            s.rect = resizeBy(r, handle: h, dx: dx, dy: dy, bounds: bounds)
        }
        return s
    }

    // MARK: 按下

    static func handleDown(_ s: inout SelectionState, at p: CGPoint,
                           hover: CGRect?, bounds: CGRect) {
        if s.phase == .hasSelection, let r = s.rect {
            let h = handle(at: p, in: r, tolerance: handleTolerance)
            switch h {
            case .outside:
                s.phase = .dragging
                s.dragStart = p
                s.rect = SelectionGeometry.normalize(from: p, to: p, in: bounds)
                s.activeHandle = nil
            case .inside:
                // 内部按下 = 整体拖动：把把手记成 inside，drag 时按位移平移
                s.phase = .resizing
                s.dragStart = p
                s.activeHandle = .inside
            default:
                s.phase = .resizing
                s.dragStart = p
                s.activeHandle = h
            }
            return
        }
        s.phase = .dragging
        s.dragStart = p
        s.activeHandle = nil
        s.pendingWindow = hover
        // 预览整窗：按下瞬间就能看到"这一下会框住哪个窗口"，
        // 但只有不拖动才最终生效
        s.rect = hover ?? SelectionGeometry.normalize(from: p, to: p, in: bounds)
    }

    // MARK: 命中判定

    /// 角优先于边：角落里同时落在 top 与 left 的容差内时，
    /// 若先判边，拖角会变成拖边，用户会觉得"角抓不住"。
    public static func handle(at p: CGPoint, in r: CGRect, tolerance t: CGFloat) -> Handle {
        let nearLeft = abs(p.x - r.minX) <= t
        let nearRight = abs(p.x - r.maxX) <= t
        let nearTop = abs(p.y - r.minY) <= t
        let nearBottom = abs(p.y - r.maxY) <= t
        let withinX = p.x >= r.minX - t && p.x <= r.maxX + t
        let withinY = p.y >= r.minY - t && p.y <= r.maxY + t

        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        if nearTop && withinX { return .top }
        if nearBottom && withinX { return .bottom }
        if nearLeft && withinY { return .left }
        if nearRight && withinY { return .right }
        return r.contains(p) ? .inside : .outside
    }

    // MARK: 缩放

    static func resize(_ r0: CGRect, handle h: Handle, from start: CGPoint, to p: CGPoint,
                       bounds: CGRect) -> CGRect {
        if h == .inside {
            var r = r0
            r.origin.x += p.x - start.x
            r.origin.y += p.y - start.y
            if r.minX < bounds.minX { r.origin.x = bounds.minX }
            if r.minY < bounds.minY { r.origin.y = bounds.minY }
            if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
            if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
            return r
        }
        var minX = r0.minX, minY = r0.minY, maxX = r0.maxX, maxY = r0.maxY
        if h == .left || h == .topLeft || h == .bottomLeft { minX = p.x }
        if h == .right || h == .topRight || h == .bottomRight { maxX = p.x }
        if h == .top || h == .topLeft || h == .topRight { minY = p.y }
        if h == .bottom || h == .bottomLeft || h == .bottomRight { maxY = p.y }
        let rect = CGRect(x: Swift.min(minX, maxX), y: Swift.min(minY, maxY),
                          width: Swift.abs(maxX - minX), height: Swift.abs(maxY - minY))
        return SelectionGeometry.normalize(from: rect.origin,
                                          to: CGPoint(x: rect.maxX, y: rect.maxY),
                                          in: bounds)
    }

    static func resizeBy(_ r: CGRect, handle h: Handle, dx: CGFloat, dy: CGFloat,
                         bounds: CGRect) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        if h == .left || h == .topLeft || h == .bottomLeft { minX += dx }
        if h == .right || h == .topRight || h == .bottomRight { maxX += dx }
        if h == .top || h == .topLeft || h == .topRight { minY += dy }
        if h == .bottom || h == .bottomLeft || h == .bottomRight { maxY += dy }
        let clamped = CGRect(x: Swift.min(minX, maxX), y: Swift.min(minY, maxY),
                             width: Swift.abs(maxX - minX), height: Swift.abs(maxY - minY))
        return SelectionGeometry.normalize(from: clamped.origin,
                                          to: CGPoint(x: clamped.maxX, y: clamped.maxY),
                                          in: bounds)
    }

    /// 键盘缩放时若还没抓把手，默认动右下角（最符合直觉）
    static func defaultHandle(for r: CGRect) -> Handle { .bottomRight }
}
