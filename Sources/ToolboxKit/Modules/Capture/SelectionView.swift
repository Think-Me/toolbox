import AppKit
import Carbon.HIToolbox

public enum CaptureCommit: Equatable, Sendable {
    case pin(CGRect)        // 选区（遮罩视图坐标，左上原点）
    case copy(CGRect)
    case save(CGRect)
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
        didSet { needsDisplay = true; positionStrip() }
    }
    public var onCommit: ((CaptureCommit) -> Void)?

    static var eventLog = CommandLine.arguments.contains("--overlay-eventlog")
    private func logEvent(_ line: String) {
        guard Self.eventLog else { return }
        FileHandle.standardError.write("OVERLAY \(line)\n".data(using: .utf8)!)
    }

    private let strip = ActionStripView()
    private let toolbar = AnnotationToolbarView()
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
        reduce(.mouseUp)
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

    private func reduce(_ action: SelectionAction) {
        logEvent("reduce \(action) → phase=\(String(describing: state.phase)) rect=\(String(describing: state.rect))")
        state = SelectionReducer.reduce(state, action, bounds: bounds, snap: snapTargets)
        logEvent("  结果 phase=\(String(describing: state.phase)) canCommit=\(state.canCommit) exit=\(state.exitRequested)")
        updateStripVisibility()
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

    // MARK: 操作条

    private func stripTapped(_ kind: ActionStripView.Kind) {
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
        case .copy: onCommit?(.copy(sel))
        case .pin: onCommit?(.pin(sel))
        case .save: onCommit?(.save(sel))
        default: break
        }
    }

    private func commit(_ kind: CaptureCommit) {
        guard state.canCommit, let sel = state.rect else { return }
        switch kind {
        case .pin: onCommit?(.pin(sel))
        case .copy: onCommit?(.copy(sel))
        case .save: onCommit?(.save(sel))
        default: break
        }
    }

    private func updateStripVisibility() {
        let show = state.canCommit
        strip.isHidden = !show
        toolbar.isHidden = !show
        if show {
            toolbar.update(selectedTool: state.annotation.tool,
                           color: state.annotation.color,
                           lineWidth: state.annotation.lineWidth,
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
        switch cmd {
        case .tool(let t):
            // 再点一次当前工具 = 退出标注，回到"拖拽改选区"
            reduce(.toolChanged(state.annotation.tool == t ? nil : t))
        case .color(let c): reduce(.annotationColor(c))
        case .lineWidth(let w): reduce(.annotationLineWidth(w))
        case .undo: reduce(.undoAnnotation)
        case .redo: reduce(.redoAnnotation)
        case .clear: reduce(.clearAnnotations)
        }
    }

    private func positionStrip() {
        guard let sel = state.rect else {
            strip.frame = .zero
            toolbar.frame = .zero
            return
        }
        let row = CaptureToolbarLayout.layout(annotationWidth: toolbar.idealSize.width,
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
        frame.size = CGSize(width: count * Self.buttonWidth + Self.edgeInset * 2,
                            height: Self.defaultHeight)
    }

    private static let defaultHeight: CGFloat = 32

    required init?(coder: NSCoder) { fatalError("不支持从 nib 构造") }

    /// 按按钮实际排布出来的尺寸，供 positionStrip 定位用。
    public var idealSize: CGSize { frame.size }

    @objc private func tapped(_ sender: NSButton) {
        let all = Kind.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        onAction?(all[sender.tag])
    }
}
