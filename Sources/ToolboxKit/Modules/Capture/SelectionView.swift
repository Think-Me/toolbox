import AppKit
import Carbon.HIToolbox

public enum CaptureCommit: Equatable, Sendable {
    /// 选区（遮罩视图坐标，左上原点）+ 该选区上的标注。
    /// 标注必须跟着一起交出去：复制/钉图/存盘三条出口都要用同一份合成结果。
    case pin(CGRect, [Annotation])
    case copy(CGRect, [Annotation])
    case save(CGRect, [Annotation])
    case cancel
    case reshot
}

/// 全屏选区遮罩。画冻结的屏幕画面 + 半透明遮罩 + 选区 + 把手 + 尺寸标签。
///
/// 坐标：视图是 flipped 的（左上原点、y 向下），所以 `SelectionState` 里的
/// topLeft 就是字面上的左上角；交给 CaptureService 裁剪时才转成像素坐标。
@MainActor
public final class SelectionView: NSView {
    private let frozen: NSImage
    private let frozenCGImage: CGImage?
    private(set) public var state = SelectionState() {
        // 顺序要紧：**先算可见性再定位**。
        // 之前是 didSet 里定位、reduce 里再改可见性，于是"第一次显示"那一趟
        // 定位读到的是旧的 isHidden，把工具条算成零宽，而之后没有新的状态变化
        // 去纠正 —— 表现就是"选完区后新增的按钮没了"。
        didSet { needsDisplay = true; updateStripVisibility(); positionStrip() }
    }
    public var onCommit: ((CaptureCommit) -> Void)?

    static var eventLog = CommandLine.arguments.contains("--overlay-eventlog")
    private func logEvent(_ line: String) {
        guard Self.eventLog else { return }
        FileHandle.standardError.write("OVERLAY \(line)\n".data(using: .utf8)!)
    }

    private let strip = ActionStripView()
    private let toolbar = AnnotationToolbarView()
    /// 文字工具的内联编辑器。nil = 没在编辑
    private var textEditor: NSTextField?
    private var annotationDefaults = AnnotationDefaults.standard
    /// 编辑器在场时要挂起的热键

    /// 工具条与操作条之间（以及两块面板各自内部）的缝隙
    private static let rowGap: CGFloat = CaptureToolbarLayout.groupGap

    // MARK: M3 交互增强（都可关：有人讨厌吸附，有人嫌放大镜挡视线）
    /// 本屏 flipped 坐标下的可框选窗口，按"从前到后"
    public var windowCandidates: [CGRect] = []
    public var snapEnabled = true
    public var magnifierEnabled = true
    /// 冻结帧的像素图：放大镜取景与取色都要用它，不能从 NSImage 反推
    public private(set) var frozenPixels: CGImage?
    public var screenScale: CGFloat = 2
    private var hoverWindow: CGRect?
    private var cursorPoint: CGPoint?
    private var tracking: NSTrackingArea?
    private var stripSize: CGSize { strip.idealSize }

    public init(screenImage: NSImage, cgImage: CGImage?) {
        self.frozen = screenImage
        self.frozenCGImage = cgImage
        self.frozenPixels = cgImage
        self.frozenPixels = cgImage
        super.init(frame: .zero)
        wantsLayer = true
        strip.onAction = { [weak self] kind in self?.stripTapped(kind) }
        toolbar.onCommand = { [weak self] cmd in self?.toolbarTapped(cmd) }
        // 字号组出现/收起会改变工具条宽度，整行必须重新居中
        toolbar.onWidthChanged = { [weak self] in self?.positionStrip() }
        addSubview(strip)
        addSubview(toolbar)
        updateStripVisibility()
    }

    required init?(coder: NSCoder) { fatalError("不支持从 nib 构造") }

    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { true }
    /// 遮罩必须吃掉所有点击：否则点空白处会穿到桌面/别的 App 上
    override public func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? self
    }

    /// accessory App 经 `open` 启动时窗口常常不是 key window，
    /// 那么第一下点击会被系统当成"激活窗口"而吞掉，视图根本收不到 mouseDown
    /// （实测：keyDown 能进、鼠标事件一个都不进）。
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 绘制

    override public func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 冻结帧必须用显式 CTM 翻转来画。
        // `NSImage.draw(in:)` 在本视图（isFlipped=true）里会把画面整个上下颠倒 ——
        // 因为 CGImage 的行序是自上而下，而 flipped 视图的 CTM 又翻了一次，
        // 两次翻叠就成了 180° 翻转（用户实测报的现象）。
        if let cg = frozenCGImage {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(origin: .zero, size: bounds.size))
            ctx.restoreGState()
        }
        let sel = state.rect ?? .zero

        // 半透明遮罩，用 even-odd 在选区处挖洞
        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.35).cgColor)
        let mask = CGMutablePath()
        mask.addRect(bounds)
        if sel.width > 0, sel.height > 0 { mask.addRect(sel) }
        // even-odd 挖洞：CGContext 的 API 是 fillPath(using:)，没有 setFillRule
        ctx.addPath(mask)
        ctx.fillPath(using: CGPathFillRule.evenOdd)

        // 悬停高亮与放大镜要在选区之前画：它们属于"取景辅助"，
        // 不该被选区边框压住，但也不能挡住选区本身
        drawHoverHighlight(in: ctx)
        drawMagnifier(in: ctx)

        guard sel.width > 0, sel.height > 0 else { return }

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(sel.integral)

        drawAnnotations(sel, in: ctx)
        drawEditingAffordance(in: ctx)
        drawHandles(sel, in: ctx)
        drawSizeLabel(sel)
    }

    /// 已完成的标注 + 正在拖的这一笔，裁剪到选区内绘制。
    /// 预览必须走 AnnotationRenderer（和导出同一个函数）：
    /// 两条路径的话"预览好看、导出走样"永远查不清。
    private func drawAnnotations(_ sel: CGRect, in ctx: CGContext) {
        var list = state.annotation.annotations
        if let d = state.annotation.draft {
            list.append(Annotation(tool: d.tool, points: d.points, color: d.color,
                                   lineWidth: d.lineWidth, fontSize: d.fontSize,
                                   filled: d.filled))
        }
        guard !list.isEmpty else { return }
        ctx.saveGState()
        // 裁剪到选区：标注只能出现在选区内，越界部分不该露出来
        ctx.clip(to: sel)
        let source = frozenPixels.map { MosaicSource(image: $0, scale: screenScale) }
        AnnotationRenderer.render(list, in: ctx, scale: 1, origin: .zero,
                                  mosaicSource: source)
        ctx.restoreGState()
    }

    /// idle 时把光标下的窗口用虚线框出来，提示"这一下点下去会框住整个窗口"。
    func drawHoverHighlight(in ctx: CGContext) {
        guard state.phase == .idle, let hover = hoverWindow else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.stroke(hover.insetBy(dx: 1, dy: 1))
        ctx.restoreGState()
    }

    /// 像素级取景 + 中心十字准星 + 光标处 HEX。
    /// 拖拽中也要显示：用户就是靠它把边线对齐到某个像素的。
    func drawMagnifier(in ctx: CGContext) {
        guard magnifierEnabled, let cursor = cursorPoint, let pixels = frozenPixels
        else { return }
        let imageSize = CGSize(width: pixels.width, height: pixels.height)
        let box = Magnifier.frame(cursor: cursor, container: bounds,
                                  size: CGSize(width: Magnifier.outputSize,
                                               height: Magnifier.outputSize
                                                    + Magnifier.labelHeight))
        let lens = CGRect(x: box.minX, y: box.minY,
                          width: Magnifier.outputSize, height: Magnifier.outputSize)
        let src = Magnifier.sourceRect(cursorInScreenPoints: cursor, scale: screenScale,
                                       imageSize: imageSize)
        guard src.width > 0, src.height > 0 else { return }

        ctx.saveGState()
        ctx.setFillColor(NSColor(calibratedWhite: 0.10, alpha: 0.98).cgColor)
        ctx.fill(box)
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.55, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(box)
        ctx.restoreGState()

        // 把源矩形映射到 lens：靠 CTM 平移+缩放实现。
        // 直接 ctx.draw(pixels, in: lens) 是错的——那会把整张屏幕压进 120pt。
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.clip(to: lens)
        ctx.translateBy(x: lens.minX, y: lens.minY)
        ctx.scaleBy(x: lens.width / src.width, y: lens.height / src.height)
        ctx.translateBy(x: -src.minX, y: -src.minY)
        ctx.draw(pixels, in: CGRect(origin: .zero, size: imageSize))
        ctx.restoreGState()

        // 中心十字准星：标出"这一像素就是要取的颜色"
        let cross = Magnifier.crosshairOffset
        let vertical: [CGPoint] = [CGPoint(x: lens.minX + cross, y: lens.minY),
                                   CGPoint(x: lens.minX + cross, y: lens.maxY)]
        let horizontal: [CGPoint] = [CGPoint(x: lens.minX, y: lens.minY + cross),
                                     CGPoint(x: lens.maxX, y: lens.minY + cross)]
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1)
        // CGContext 没有 strokeLines，画线段要用 strokeLineSegments(between: [CGPoint])
        ctx.strokeLineSegments(between: vertical)
        ctx.strokeLineSegments(between: horizontal)
        ctx.restoreGState()

        let hex = Magnifier.hexColor(of: pixels,
                                     pixelX: Int((cursor.x * screenScale).rounded()),
                                     pixelY: Int((cursor.y * screenScale).rounded()))
        drawMagnifierInfo(hex: hex,
                          in: CGRect(x: box.minX, y: lens.maxY,
                                     width: box.width, height: Magnifier.labelHeight))
    }

    private func drawMagnifierInfo(hex: String?, in rect: CGRect) {
        guard let hex else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        (hex as NSString).draw(at: CGPoint(x: rect.minX + 6, y: rect.midY - 6),
                               withAttributes: attrs)
        if let color = NSColor(hexString: hex) {
            color.setFill()
            NSBezierPath(rect: CGRect(x: rect.maxX - 26, y: rect.midY - 7,
                                      width: 20, height: 14)).fill()
        }
    }

    private func drawHandles(_ sel: CGRect, in ctx: CGContext) {
        ctx.setFillColor(NSColor.white.cgColor)
        for p in handlePoints(of: sel) {
            ctx.fill(CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
        }
    }

    private func handlePoints(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY),
         CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private func drawSizeLabel(_ sel: CGRect) {
        let text = "\(Int(sel.width)) × \(Int(sel.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor(calibratedWhite: 0, alpha: 0.7),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        // 优先放选区内左上角；选区太小时放选区外侧上方
        var origin = CGPoint(x: sel.minX + 4, y: sel.minY + 4)
        if sel.width < size.width + 12 || sel.height < size.height + 12 {
            origin = CGPoint(x: sel.minX, y: Swift.max(0, sel.minY - size.height - 4))
        }
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }

    // MARK: 鼠标

    override public func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if textEditor != nil {
            // 正在打字时点别处：提交这一行，然后**继续处理这一下点击**，
            // 不要 return。之前直接 return 把点击吞掉，导致"想加第二个文字块
            // 必须先空点一次"，用户反馈要来回切工具才行。
            endTextEditing(commit: true)
            if state.annotation.tool == .text {
                beginTextEditing(at: p.clamped(to: state.rect ?? bounds))
                return
            }
        }
        let hover = state.phase == .idle
            ? (hoverWindow ?? SelectionSnapping.topmostWindow(containing: p, in: windowCandidates))
            : nil
        // 整窗选中与否交给 reducer：它要看"按下后有没有拖动"
        reduce(.mouseDown(p, hover: hover))
    }

    override public func mouseDragged(with event: NSEvent) {
        reduce(.mouseDragged(convert(event)))
    }

    override public func mouseUp(with event: NSEvent) {
        logEvent("mouseUp")
        let wasText = state.annotation.tool == .text
        reduce(.mouseUp)
        // 点了一下已有文字块（位移没超阈值）= 重新编辑它
        if let id = state.annotation.tappedID,
           let a = state.annotation.annotations.first(where: { $0.id == id }),
           a.tool == .text, let anchor = a.points.first {
            beginTextEditing(at: anchor, existing: a)
            return
        }
        if wasText, let anchor = state.annotation.textAnchor { beginTextEditing(at: anchor) }
    }

    private func convert(_ event: NSEvent) -> CGPoint {
        // event.locationInWindow 是未翻转的窗口坐标，转成视图的 flipped 坐标
        convert(event.locationInWindow, from: nil)
    }

    private var snapTargets: SnapTargets? {
        guard snapEnabled else { return nil }
        return SelectionSnapping.targets(windows: windowCandidates, screen: bounds)
    }

    /// 调试探针用：不经过鼠标键盘，把一串 action 走**同一个 reducer** 摆好状态。
    /// 之所以用真 action 而不是直接塞 state：这样探针验证的就是实际交互路径，
    /// 免得"探针能显示、真点却坏了"。
    public func applyForProbe(_ actions: [SelectionAction]) {
        for a in actions { reduce(a) }
    }

    /// 按下这一点落在哪个已画图形上。只有 mouseDown 需要算：
    /// 它决定"这一下是移动已有图形，还是改选区/画新图形"
    private static func hitID(for action: SelectionAction,
                              in list: [Annotation]) -> UUID? {
        guard case .mouseDown(let p, _) = action, !list.isEmpty else { return nil }
        return AnnotationHitTest.topmost(at: p, in: list)
    }

    private func reduce(_ action: SelectionAction) {
        logEvent("reduce \(action) → phase=\(String(describing: state.phase)) rect=\(String(describing: state.rect))")
        state = SelectionReducer.reduce(state, action, bounds: bounds, snap: snapTargets,
                                        hit: Self.hitID(for: action, in: state.annotation.annotations))
        logEvent("  结果 phase=\(String(describing: state.phase)) canCommit=\(state.canCommit) exit=\(state.exitRequested)")
        if state.exitRequested { onCommit?(.cancel) }
    }

    // MARK: 键盘

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursorPoint = p
        guard phaseAllowsHoverHighlight else { hoverWindow = nil; needsDisplay = true; return }
        let next = SelectionSnapping.topmostWindow(containing: p, in: windowCandidates)
        if next != hoverWindow { hoverWindow = next }
        needsDisplay = true      // 放大镜要跟着光标走，每帧都得重绘
    }

    public override func mouseExited(with event: NSEvent) {
        hoverWindow = nil
        cursorPoint = nil
        needsDisplay = true
    }

    private var phaseAllowsHoverHighlight: Bool { state.phase == .idle }

    override public func keyDown(with event: NSEvent) {
        logEvent("keyDown code=\(event.keyCode)")
        // 键事件能落到这里，说明输入框**没有**消费它（正常打字时键是发给
        // field editor 的，根本不会走到这）。所以这里先收掉编辑器，
        // 然后**继续**按下面的正常逻辑处理这个键。
        // 之前是直接 super.keyDown + return：输入框一旦没拿到焦点，
        // Esc / 回车 / ⌘C 全部失效，遮罩变成关不掉的死屏。
        if textEditor != nil { endTextEditing(commit: true) }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case UInt16(kVK_Escape): reduce(.escape)
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter): commit(.pin)
        case UInt16(kVK_LeftArrow): reduce(shift ? .resizeNudge(dx: -1, dy: 0) : .nudge(dx: -1, dy: 0))
        case UInt16(kVK_RightArrow): reduce(shift ? .resizeNudge(dx: 1, dy: 0) : .nudge(dx: 1, dy: 0))
        case UInt16(kVK_UpArrow): reduce(shift ? .resizeNudge(dx: 0, dy: -1) : .nudge(dx: 0, dy: -1))
        case UInt16(kVK_DownArrow): reduce(shift ? .resizeNudge(dx: 0, dy: 1) : .nudge(dx: 0, dy: 1))
        case UInt16(kVK_ANSI_C) where event.modifierFlags.contains(.command): commit(.copy)
        case UInt16(kVK_ANSI_S) where event.modifierFlags.contains(.command): commit(.save)
        case UInt16(kVK_ANSI_Z) where event.modifierFlags.contains(.command):
            reduce(event.modifierFlags.contains(.shift) ? .redoAnnotation : .undoAnnotation)
        default: break
        }
    }

    // MARK: 文字工具的内联编辑

    /// 在锚点起一个内联输入框。
    /// 不用 NSPanel/单独窗口：那会引入"焦点在别处、遮罩收不到键"的一类问题，
    /// 而且贴图画面的坐标对齐要再算一层。
    /// 正在编辑的是哪个已有文字块（nil = 新建）
    private var editingAnnotationID: UUID?

    private func beginTextEditing(at anchor: CGPoint, existing: Annotation? = nil) {
        endTextEditing(commit: false)
        editingAnnotationID = existing?.id
        guard let sel = state.rect else { return }
        let size = state.annotation.fontSize * 1.45
        let width = Swift.min(Self.maxEditingWidth, Swift.max(120, sel.maxX - anchor.x))
        let f = NSTextField(frame: CGRect(x: anchor.x, y: anchor.y, width: width, height: size))
        f.isBordered = false
        f.isBezeled = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.lineBreakMode = .byClipping
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.cell?.usesSingleLineMode = true
        f.font = NSFont.systemFont(ofSize: state.annotation.fontSize, weight: .semibold)
        f.textColor = state.annotation.color.nsColor
        // 插入点在 NSTextField 上没有直接属性：它用的是窗口共享的 field editor
        if let existing {
            f.stringValue = existing.text ?? ""
            state.annotation.fontSize = existing.fontSize
        }
        f.delegate = self
        f.placeholderAttributedString = NSAttributedString(
            string: "输入文字",
            attributes: [.foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.45),
                         .font: NSFont.systemFont(ofSize: state.annotation.fontSize,
                                                  weight: .semibold)])
        addSubview(f)
        textEditor = f
        // 顺序要紧：**先让窗口成为 key，再设 first responder**。
        // 反过来写时 makeKeyAndOrderFront 会重排 first responder，
        // 输入框拿不到键盘 —— 于是打字进不去、回车和 Esc 全被下面的
        // "编辑器优先"逻辑吞掉，编辑器再也关不掉，热键一直挂着。
        // （用户一次报的三个症状同源）
        window?.makeKeyAndOrderFront(nil)
        applyEditorFocus(to: f)
        needsDisplay = true
    }

    /// 要焦点 + 设插入点颜色 + 挂热键闸门。
    ///
    /// 紧接着上一个编辑器 `removeFromSuperview` 时，同步 `makeFirstResponder`
    /// 有时会失败（共享的 field editor 还在收尾），所以**先试一次，
    /// 不行就下一轮 runloop 再试**。不这么做的话第二个文字块会"框在但打不进字"。
    private func applyEditorFocus(to f: NSTextField, retry: Bool = true) {
        window?.makeKeyAndOrderFront(nil)
        let took = window?.makeFirstResponder(f) ?? false
        if let editor = window?.fieldEditor(true, for: f) as? NSTextView {
            // 深色画面上默认的黑光标几乎看不见
            editor.insertionPointColor = .white
        }
        if took {
            HotkeyCenter.shared.textEditingHost = self
            return
        }
        guard retry, textEditor === f else {
            logEvent("TEXTEDIT 输入框拿不到焦点")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.textEditor === f else { return }
            self.applyEditorFocus(to: f, retry: false)
        }
    }

    private static let maxEditingWidth: CGFloat = 520

    /// 输入中的文字块要有明显的"可以在这里打字"的信号：
    /// 半透明底 + 一条当前颜色的下划线。只靠占位文字太弱，
    /// 用户分不清"框在这儿"和"已经打完了"。
    private func drawEditingAffordance(in ctx: CGContext) {
        guard let f = textEditor else { return }
        let r = f.frame
        ctx.saveGState()
        ctx.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 0.55).cgColor)
        ctx.fill(r.insetBy(dx: -4, dy: -2))
        let color = state.annotation.color.nsColor
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: r.minX - 4, y: r.maxY + 1))
        ctx.addLine(to: CGPoint(x: r.maxX + 4, y: r.maxY + 1))
        ctx.strokePath()
        // 左右两个端点小方块：让"输入区间的边界"看得出来
        ctx.setFillColor(color.cgColor)
        for x in [r.minX - 4, r.maxX + 4] {
            ctx.fill(CGRect(x: x - 2, y: r.maxY - 1, width: 4, height: 4))
        }
        ctx.restoreGState()
    }

    /// 遮罩收口时调用。不提交内容，只保证"编辑器不留存、热键不悬空"。
    public func closeEditorForDismiss() {
        guard textEditor != nil else { return }
        textEditor?.removeFromSuperview()
        textEditor = nil
        HotkeyCenter.shared.textEditingHost = nil
        needsDisplay = true
    }

    /// - Parameter typed: 正在编辑时的实时内容。
    /// **不能读 `f.stringValue`**：编辑过程中它还是"上一次提交的值"（首次输入即空串），
    /// 实时文本在共享的 field editor 里。读错的表现就是"打的字全不保存"。
    private func endTextEditing(commit: Bool, typed: String? = nil) {
        guard let f = textEditor else { return }
        textEditor = nil
        let editing = editingAnnotationID
        editingAnnotationID = nil
        let text = typed ?? f.currentEditor()?.string ?? f.stringValue
        f.removeFromSuperview()
        if textEditor == nil { HotkeyCenter.shared.textEditingHost = nil }
        if commit {
            reduce(.commitText(text, fontSize: state.annotation.fontSize, editing: editing))
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// 应用设置页里的标注默认值。工具条关掉时整行只剩操作条。
    public func applyAnnotationDefaults(_ d: AnnotationDefaults) {
        annotationDefaults = d
        state.annotation.color = d.color
        state.annotation.lineWidth = d.lineWidth
        updateStripVisibility()
        positionStrip()
    }

    // MARK: 操作条

    private func stripTapped(_ kind: ActionStripView.Kind) {
        if textEditor != nil { endTextEditing(commit: true) }
        switch kind {
        case .copy: commit(.copy)
        case .pin: commit(.pin)
        case .save: commit(.save)
        case .reshot: onCommit?(.reshot)
        case .cancel: onCommit?(.cancel)
        }
    }

    private func commit(_ kind: ActionStripView.Kind) {
        guard state.canCommit, let sel = state.rect else { return }
        switch kind {
        case .copy: onCommit?(.copy(sel, state.annotation.annotations))
        case .pin: onCommit?(.pin(sel, state.annotation.annotations))
        case .save: onCommit?(.save(sel, state.annotation.annotations))
        default: break
        }
    }

    private func updateStripVisibility() {
        let show = state.canCommit
        strip.isHidden = !show
        toolbar.isHidden = !show || !annotationDefaults.toolbarEnabled
        if show {
            toolbar.update(selectedTool: state.annotation.tool,
                           color: state.annotation.color,
                           lineWidth: state.annotation.lineWidth,
                           fontSize: state.annotation.fontSize,
                           canUndo: state.annotation.canUndo,
                           canRedo: state.annotation.canRedo,
                           hasAnnotations: !state.annotation.annotations.isEmpty)
        }
        updateCursor()
    }

    private func updateCursor() {
        // 活动工具下要换成分划线：用户得知道这一下拖拽是画标注而不是改选区
        if let w = window { w.invalidateCursorRects(for: self) }
    }

    override public func resetCursorRects() {
        if state.annotation.isActive {
            addCursorRect(bounds, cursor: .crosshair)
        } else {
            super.resetCursorRects()
        }
    }

    private func toolbarTapped(_ cmd: AnnotationToolbarView.Command) {
        // 正在打字时点工具条 = 先提交这行字。否则输入框会僵在原处，
        // 而且热键挂起状态会被拖长到不可预期的时刻
        if textEditor != nil { endTextEditing(commit: true) }
        switch cmd {
        case .tool(let t):
            // 再点一次当前工具 = 退出标注，回到"拖拽改选区"
            reduce(.toolChanged(state.annotation.tool == t ? nil : t))
        case .color(let c): reduce(.annotationColor(c))
        case .lineWidth(let w): reduce(.annotationLineWidth(w))
        case .fontSize(let s): reduce(.annotationFontSize(s))
        case .undo: reduce(.undoAnnotation)
        case .redo: reduce(.redoAnnotation)
        case .clear: reduce(.clearAnnotations)
        }
    }

    private func positionStrip() {
        // 没有选区时**只靠 isHidden 控制可见性**，别把 frame 清成 .zero：
        // 曾经这么写过，配合"idealSize 读 frame.size"就把按钮宽度永久归零了
        guard let sel = state.rect else { return }
        // 用设置值而不是 toolbar.isHidden：布局不该依赖"这一趟有没有正好更新过可见性"
        let barWidth: CGFloat = annotationDefaults.toolbarEnabled ? toolbar.visibleWidth : 0
        let row = CaptureToolbarLayout.layout(annotationWidth: barWidth,
                                              actionWidth: stripSize.width,
                                              selection: sel, container: bounds)
        toolbar.frame = row.annotationBar
        strip.frame = row.actionBar
    }
}

/// 选区下方的操作条：纯图标按钮（用户要求，不用文字）。
///
/// 每个按钮都带 tooltip 说明动作与快捷键 —— 图标本身表意有限，
/// 去掉文字就必须把可读性补回来。
@MainActor
public final class ActionStripView: NSView {
    public enum Kind: CaseIterable { case copy, pin, save, reshot, cancel }
    public var onAction: ((Kind) -> Void)?

    private static let buttonWidth: CGFloat = 34
    private static let buttonHeight: CGFloat = 28
    private static let edgeInset: CGFloat = 5

    private let symbols: [Kind: String] = [
        .copy: "doc.on.clipboard", .pin: "pin.fill", .save: "square.and.arrow.down",
        .reshot: "arrow.counterclockwise", .cancel: "xmark",
    ]
    private let titles: [Kind: String] = [
        .copy: "复制", .pin: "钉图", .save: "存盘", .reshot: "重选", .cancel: "取消",
    ]
    private let hints: [Kind: String] = [
        .copy: "复制到剪贴板 (⌘C)", .pin: "钉到屏幕 (⏎)", .save: "存为文件 (⌘S)",
        .reshot: "重新框选", .cancel: "取消 (Esc)",
    ]

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 0.96).cgColor
        layer?.cornerRadius = 7
        layer?.borderColor = NSColor(calibratedWhite: 0.42, alpha: 1).cgColor
        layer?.borderWidth = 1
        for (i, kind) in Kind.allCases.enumerated() {
            let b = NSButton(frame: .zero)
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imagePosition = .imageOnly
            b.title = ""
            b.target = self
            b.action = #selector(tapped(_:))
            b.tag = i
            b.toolTip = hints[kind]
            b.setButtonType(.momentaryChange)
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            b.image = NSImage(systemSymbolName: symbols[kind] ?? "questionmark",
                              accessibilityDescription: titles[kind])?
                .withSymbolConfiguration(cfg)
            b.contentTintColor = kind == .cancel
                ? NSColor(calibratedWhite: 0.72, alpha: 1)
                : NSColor(calibratedWhite: 0.94, alpha: 1)
            b.frame = CGRect(x: Self.edgeInset + CGFloat(i) * Self.buttonWidth,
                             y: (Self.defaultHeight - Self.buttonHeight) / 2,
                             width: Self.buttonWidth, height: Self.buttonHeight)
            addSubview(b)
        }
        let count = CGFloat(Kind.allCases.count)
        intrinsicWidth = count * Self.buttonWidth + Self.edgeInset * 2
        frame.size = CGSize(width: intrinsicWidth, height: Self.defaultHeight)
    }

    /// 按按钮排布算出来的固有宽度。
    /// **绝不能从 frame.size 反推**：positionStrip 会在没有选区时把 frame 清零，
    /// 那样宽度就永久变成 0，表现为"选完区后按钮全没了"（可见但零宽）。
    /// 用 var 是 Swift 定值初始化规则：init 里调过实例方法后再给 let 赋值会报错
    private var intrinsicWidth: CGFloat = 0

    private static let defaultHeight: CGFloat = 32

    required init?(coder: NSCoder) { fatalError("不支持从 nib 构造") }

    /// 供同一行布局定位用
    public var idealSize: CGSize { CGSize(width: intrinsicWidth, height: Self.defaultHeight) }

    @objc private func tapped(_ sender: NSButton) {
        let all = Kind.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        onAction?(all[sender.tag])
    }
}


// MARK: - 内联文字编辑器

@MainActor
extension SelectionView: NSTextFieldDelegate {
    /// 回车提交、Esc 取消。返回 true 表示这个键已经用掉，别再往上抛
    /// （否则 Esc 会被遮罩当成"取消截图"，回车会被当成"钉图"）。
    nonisolated public func control(_ control: NSControl, textView: NSTextView,
                                    doCommandBy commandSelector: Selector) -> Bool {
        // 协议要求 nonisolated，但这个回调只可能在主线程来
        MainActor.assumeIsolated {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                endTextEditing(commit: true, typed: textView.string)
            case #selector(NSResponder.cancelOperation(_:)):
                endTextEditing(commit: false)
            default:
                return
            }
        }
        return true
    }
}
