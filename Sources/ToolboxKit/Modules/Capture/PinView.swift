import AppKit
import Carbon.HIToolbox

/// 贴图的内容视图：负责画图和把手势翻译成对 `PinZoomModel` 的操作。
@MainActor
final class PinView: NSView {
    var model: PinZoomModel { didSet { needsDisplay = true } }
    let image: NSImage
    var onModelChanged: (() -> Void)?
    var destroy: (() -> Void)?
    var togglePassthrough: (() -> Void)?
    var copyToClipboard: (() -> Void)?
    var saveToFile: (() -> Void)?
    var toggleAlwaysOnTop: (() -> Void)?
    /// 滚轮方向由设置决定，用注入而不是读全局单例：
    /// 视图层拿不到也不该拿到"当前设置"这种全局状态，否则测试和依赖方向都失控。
    /// +1 = 双指上滑放大（默认），-1 = 上滑缩小。
    var magnifySignProvider: () -> CGFloat = { 1 }

    private lazy var cgImage: CGImage? = {
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }()

    private var dragStartScreenPoint: CGPoint?
    private var dragStartWindowOrigin: CGPoint?
    private var isDragging = false

    /// 双击销毁与拖动的分界：位移超过这个值才算拖动
    static let dragThreshold: CGFloat = 3
    private static let opacityStep: CGFloat = 0.05

    init(model: PinZoomModel, image: NSImage) {
        self.model = model
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: model.contentSize))
        wantsLayer = true
        // 捏合缩放不需要 allowsMagnification（那是 NSScrollView 的属性）：
        // NSResponder 本身就有 magnifyWithEvent:，覆写它即可收到 .magnify 事件
        toolTip = "拖动移动 · 双指上下滑/捏合缩放 · 双击关闭 · 右键更多"
    }

    required init?(coder: NSCoder) { fatalError("不支持从 nib 构造") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    /// 贴图常常不是当前 active App 的窗口；不返回 true 的话"点一下"要先激活窗口，
    /// 用户就会觉得第一下点击没反应。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = model.usesNearestNeighbor ? .none : .high
        ctx.saveGState()
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        ctx.rotate(by: CGFloat(model.rotationDegrees) * .pi / 180)
        let dest = CGRect(x: -bounds.width / 2, y: -bounds.height / 2,
                          width: bounds.width, height: bounds.height)
        // 直接画 CGImage：NSImage.draw 走 rep 自己的绘制路径，
        // 上面设的 ctx.interpolationQuality 不一定生效（实测糊成一片）
        if let cg = cgImage { ctx.draw(cg, in: dest) }
        ctx.restoreGState()
    }

    // MARK: 缩放

    static var eventLog = CommandLine.arguments.contains("--pin-eventlog")
    private func logEvent(_ line: String) {
        guard Self.eventLog else { return }
        FileHandle.standardError.write("EVENT \(line)\n".data(using: .utf8)!)
    }

    override func scrollWheel(with event: NSEvent) {
        logEvent("scroll precise=\(event.hasPreciseScrollingDeltas) scrollingDeltaY=\(event.scrollingDeltaY) deltaY=\(event.deltaY) location=\(event.locationInWindow)")
        // ⌥+滚动 = 调透明度，不缩放
        let optionHeld = event.modifierFlags.contains(.option)
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.deltaY * 4        // 鼠标滚轮一格走大步长
        guard delta != 0 else { return }
        if optionHeld {
            model.adjustOpacity(by: delta > 0 ? Self.opacityStep : -Self.opacityStep)
        } else {
            model.apply(delta: delta, magnifySign: magnifySignProvider())
        }
        onModelChanged?()
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        logEvent("magnify delta=\(event.magnification)")
        model.applyMagnificationDelta(event.magnification)
        onModelChanged?()
        needsDisplay = true
    }

    // MARK: 移动 / 双击销毁

    override func mouseDown(with event: NSEvent) {
        logEvent("mouseDown clickCount=\(event.clickCount) loc=\(event.locationInWindow)")
        // 顺序不能反：双击的第二下必须早于任何拖拽判定生效，
        // 否则会被当成一次微小拖动，销毁永远触发不了
        if event.clickCount >= 2 {
            destroy?()
            return
        }
        guard let window else { super.mouseDown(with: event); return }
        dragStartScreenPoint = NSEvent.mouseLocation
        dragStartWindowOrigin = window.frame.origin
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartScreenPoint, let origin = dragStartWindowOrigin,
              let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if !isDragging && hypot(dx, dy) < Self.dragThreshold { return }
        if !isDragging {
            isDragging = true
            window.alphaValue = 0.85          // 拖动中半透明，大图跟手时不显得撕裂
        }
        window.setFrameOrigin(CGPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging { window?.alphaValue = model.opacity }
        dragStartScreenPoint = nil
        dragStartWindowOrigin = nil
        isDragging = false
    }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            switch event.keyCode {
            case UInt16(kVK_ANSI_W): destroy?(); return
            case UInt16(kVK_ANSI_C): copyToClipboard?(); return
            case UInt16(kVK_ANSI_S): saveToFile?(); return
            default: break
            }
        }
        switch event.keyCode {
        case UInt16(kVK_ANSI_R): model.rotate90(); onModelChanged?(); needsDisplay = true
        case UInt16(kVK_ANSI_X): togglePassthrough?()
        case UInt16(kVK_ANSI_0): model.reset(); onModelChanged?(); needsDisplay = true
        case UInt16(kVK_ANSI_Equal), UInt16(kVK_ANSI_KeypadPlus):
            model.step(by: 1); onModelChanged?(); needsDisplay = true
        case UInt16(kVK_ANSI_Minus):
            model.step(by: -1); onModelChanged?(); needsDisplay = true
        case UInt16(kVK_Escape): destroy?()
        default: super.keyDown(with: event)
        }
    }

    // MARK: 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("复制图片", #selector(menuCopy))
        add("存为文件…", #selector(menuSave))
        menu.addItem(.separator())
        add("永远置顶", #selector(menuTop))
        add("鼠标穿透（按 F3 收回全部）", #selector(menuPassthrough))
        menu.addItem(.separator())
        add("旋转 90°", #selector(menuRotate))
        add("恢复原始大小", #selector(menuReset))
        menu.addItem(.separator())
        add("关闭", #selector(menuClose))
        return menu
    }

    @objc private func menuCopy() { copyToClipboard?() }
    @objc private func menuSave() { saveToFile?() }
    @objc private func menuTop() { toggleAlwaysOnTop?() }
    @objc private func menuPassthrough() { togglePassthrough?() }
    @objc private func menuRotate() { model.rotate90(); onModelChanged?(); needsDisplay = true }
    @objc private func menuReset() { model.reset(); onModelChanged?(); needsDisplay = true }
    @objc private func menuClose() { destroy?() }
}
