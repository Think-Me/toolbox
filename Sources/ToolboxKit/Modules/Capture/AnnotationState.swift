import CoreGraphics
import Foundation

/// 正在画的**这一笔**。没抬笔就不进图形列表，也就不进撤销栈。
public struct AnnotationDraft: Equatable, Sendable {
    public let tool: AnnotationTool
    public var points: [CGPoint]
    public var color: AnnotationColor
    public var lineWidth: CGFloat
    public var fontSize: CGFloat
    public var filled: Bool

    init(tool: AnnotationTool, start: CGPoint, color: AnnotationColor,
         lineWidth: CGFloat, fontSize: CGFloat, filled: Bool) {
        self.tool = tool; self.points = [start]; self.color = color
        self.lineWidth = lineWidth; self.fontSize = fontSize; self.filled = filled
    }

    var isStroke: Bool { tool == .pen }
}

/// 标注子状态机。和选区状态机分开，是为了让"工具非空时拖拽画标注、
/// 工具为 nil 时拖拽改选区"这条规则在 reducer 顶部一眼可见。
public struct AnnotationState: Equatable {
    /// 画笔抽稀容差（point）。3pt 内的抖动看不出来，但能让一笔从上千点降到几十点
    public static let sampleTolerance: CGFloat = 3

    /// nil = 不画标注，鼠标归选区逻辑管
    public var tool: AnnotationTool?
    public var color = AnnotationPalette.defaultColor
    public var lineWidth: CGFloat = AnnotationPalette.defaultLineWidth
    public var fontSize: CGFloat = AnnotationPalette.defaultFontSize
    public var filled = false

    public var annotations: [Annotation] = []
    public var history = AnnotationHistory()
    public var draft: AnnotationDraft?
    /// 文字工具落点。抬起笔时草稿会被丢掉，但落点要留着给内联编辑器提交
    public var textAnchor: CGPoint?

    /// 正在拖动哪个图形（移动已画好的标注）。nil = 没在移动
    public var movingID: UUID?
    /// 抬手时若位移没超过阈值，算"点了一下"而不是"拖动"——
    /// 文字图形靠这个决定是重新打开编辑器还是移动
    public var tappedID: UUID?
    private var moveStart: CGPoint?
    private var moveBase: [CGPoint]?
    private var didDragMove = false
    /// 和选区"单击整窗 vs 拖动自由框"用同一个阈值，手感才一致
    public static let moveDragThreshold: CGFloat = 4

    public init() {}

    public var isActive: Bool { tool != nil }
    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    public mutating func setTool(_ new: AnnotationTool?) {
        // 换工具必须丢掉草稿：否则起笔时是画笔、中途切箭头，
        // 抬笔会拿箭头的画法去渲染一堆画笔点
        draft = nil
        tool = new
    }

    public mutating func down(at raw: CGPoint, in sel: CGRect) {
        guard let tool, sel.width >= 1, sel.height >= 1 else { return }
        let p = raw.clamped(to: sel)
        if tool == .text { textAnchor = p }
        tappedID = nil
        draft = AnnotationDraft(tool: tool, start: p, color: color,
                                lineWidth: lineWidth, fontSize: fontSize, filled: filled)
    }

    public mutating func drag(to raw: CGPoint, in sel: CGRect) {
        guard var d = draft else { return }
        let p = raw.clamped(to: sel)
        if d.isStroke {
            // 画笔只收"和上一点有位移"的点，拖拽事件本身就能有上千个
            if let last = d.points.last, hypot(p.x - last.x, p.y - last.y) >= 1 {
                d.points.append(p)
            }
        } else {
            guard let start = d.points.first else { return }
            d.points = [start, p]
        }
        draft = d
    }

    public mutating func up() {
        defer { draft = nil }
        guard let d = draft else { return }
        var points = d.points
        if d.isStroke {
            points = AnnotationGeometry.simplify(points, tolerance: Self.sampleTolerance)
        }
        let a = Annotation(tool: d.tool, points: points, color: d.color,
                           lineWidth: d.lineWidth, fontSize: d.fontSize, filled: d.filled)
        // 只产生 1 个点的笔画（手抖）直接丢掉：不进列表也不进撤销栈
        guard a.isComplete, d.tool != .text else { return }
        annotations.append(a)
        history.commit(annotations)
    }

    /// 内联编辑器回车后调用。
    /// - Parameter editing: 非 nil 表示**改的是已有那块**（点文字块重新编辑的入口），
    ///   而不是叠加一块新的。文字被清空则整块删掉——留着空文字块只会让人以为坏了。
    public mutating func commitText(_ text: String, fontSize: CGFloat, editing: UUID? = nil) {
        guard tool == .text else { return }
        if let id = editing, let idx = annotations.firstIndex(where: { $0.id == id }) {
            var a = annotations[idx]
            a.text = text
            a.fontSize = fontSize
            if a.isComplete {
                annotations[idx] = a
            } else {
                annotations.remove(at: idx)
            }
            history.commit(annotations)
            return
        }
        guard let anchor = textAnchor else { return }
        let a = Annotation(tool: .text, points: [anchor], color: color,
                           lineWidth: lineWidth, text: text, fontSize: fontSize)
        guard a.isComplete else { return }
        annotations.append(a)
        history.commit(annotations)
    }

    // MARK: 移动已画好的图形

    public mutating func beginMove(id: UUID, at p: CGPoint) {
        draft = nil
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        movingID = id
        moveStart = p
        moveBase = annotations[idx].points
        tappedID = nil
        didDragMove = false
    }

    public mutating func dragMove(to raw: CGPoint, in sel: CGRect) {
        guard let id = movingID, let start = moveStart, let base = moveBase,
              let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        // 钳的是**图形整体**而不是光标：只钳光标的话，图形仍会有一半被推出选区
        // （导出时按选区裁剪，出去的就是缺角的图）
        let bb = AnnotationGeometry.boundingBox(of: base)
        var dx = raw.x - start.x, dy = raw.y - start.y
        dx = Swift.max(sel.minX - bb.minX, Swift.min(dx, sel.maxX - bb.maxX))
        dy = Swift.max(sel.minY - bb.minY, Swift.min(dy, sel.maxY - bb.maxY))
        if hypot(dx, dy) > Self.moveDragThreshold { didDragMove = true }
        // 以**按下时的点集**为基准加总位移，绝不拿上一帧结果再叠一次
        // （选区拖动就踩过这个坑，表现是越拖越快）
        var moved = annotations[idx]
        moved.points = base.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        annotations[idx] = moved
    }

    public mutating func endMove() {
        defer { movingID = nil; moveStart = nil; moveBase = nil; didDragMove = false }
        guard let id = movingID else { return }
        if didDragMove {
            // 只在真的动过时压一步，否则撤销栈里全是"原地不动"
            history.commit(annotations)
        } else if let idx = annotations.firstIndex(where: { $0.id == id }),
                  let base = moveBase {
            // 没超过阈值 = 一次点击（文字块靠它决定重开编辑器）。
            // 必须把拖动过程中的临时偏移**还原**，否则"点一下"会让图形悄悄挪 1~3pt
            tappedID = id
            var restored = annotations[idx]
            restored.points = base
            annotations[idx] = restored
        } else {
            tappedID = id
        }
    }

    public mutating func undo() {
        draft = nil; movingID = nil
        if let prev = history.undo() { annotations = prev }
    }

    public mutating func redo() {
        draft = nil; movingID = nil
        if let next = history.redo() { annotations = next }
    }

    public mutating func clear() {
        draft = nil; movingID = nil
        // 已经是空的就别 commit：否则撤销栈里多出一个"什么都没变"的步骤
        guard !annotations.isEmpty else { return }
        annotations = []
        history.commit(annotations)
    }

}

extension CGPoint {
    func clamped(to rect: CGRect) -> CGPoint {
        CGPoint(x: Swift.min(Swift.max(x, rect.minX), rect.maxX),
                y: Swift.min(Swift.max(y, rect.minY), rect.maxY))
    }
}
