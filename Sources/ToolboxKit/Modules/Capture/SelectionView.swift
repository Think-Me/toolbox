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
    private var stripSize: CGSize { strip.idealSize }

    public init(screenImage: NSImage, cgImage: CGImage?) {
        self.frozen = screenImage
        self.frozenCGImage = cgImage
        super.init(frame: .zero)
        wantsLayer = true
        strip.onAction = { [weak self] kind in self?.stripTapped(kind) }
        addSubview(strip)
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

        guard sel.width > 0, sel.height > 0 else { return }

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(sel.integral)

        drawHandles(sel, in: ctx)
        drawSizeLabel(sel)
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
        reduce(.mouseDown(convert(event)))
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

    private func reduce(_ action: SelectionAction) {
        logEvent("reduce \(action) → phase=\(String(describing: state.phase)) rect=\(String(describing: state.rect))")
        state = SelectionReducer.reduce(state, action, bounds: bounds)
        logEvent("  结果 phase=\(String(describing: state.phase)) canCommit=\(state.canCommit) exit=\(state.exitRequested)")
        updateStripVisibility()
        if state.exitRequested { onCommit?(.cancel) }
    }

    // MARK: 键盘

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
        strip.isHidden = !state.canCommit
    }

    private func positionStrip() {
        guard let sel = state.rect else { strip.frame = .zero; return }
        strip.frame = SelectionGeometry.stripFrame(for: sel, strip: stripSize,
                                                   container: bounds)
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
