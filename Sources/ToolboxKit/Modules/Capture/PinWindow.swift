import AppKit

/// 一张贴图的窗口。
///
/// 三个配置项是需求硬指标，少一个就会有用户报"切了 Space 贴图不见了"：
/// - `.canJoinAllSpaces`     切 Space 仍在
/// - `.fullScreenAuxiliary`  全屏 App 之上仍可见
/// - `.nonactivatingPanel`   点贴图不会把焦点从原来的 App 抢走
@MainActor
public final class PinWindow: NSPanel {
    public let id = UUID()
    /// 原始图像。复制/存盘必须用它 —— 显示时可能降采样过，
    /// 导出若走显示路径会悄悄掉画质。
    public let sourceImage: NSImage
    /// 只读转发给 PinView。手势改的是视图那份，窗口必须读同一份才能把结果落到 frame 上。
    public var model: PinZoomModel { pinView.model }
    private let pinView: PinView
    var onClose: ((UUID) -> Void)?

    /// 贴图窗口本身不缩放内容：改 zoom 时重算 frame，保持中心不动（Snipaste 行为）
    /// 入参改名 `initialModel`：`model` 现在是计算属性，
    /// init 里同名参数会被解析成 self.model，super.init 之前读它会编译失败。
    public init(image: NSImage, initialModel: PinZoomModel, screenFrame: CGRect) {
        self.sourceImage = image
        self.pinView = PinView(model: initialModel, image: image)
        let initial = SelectionGeometry.clampedToScreen(
            CGRect(origin: screenFrame.origin, size: initialModel.contentSize),
            screen: screenFrame, visible: screenFrame)
        super.init(contentRect: initial,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false                 // 自己实现拖动，见 PinView
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        alphaValue = model.opacity
        contentView = pinView
        pinView.onModelChanged = { [weak self] in self?.applyModel() }
        pinView.destroy = { [weak self] in self?.destroyAnimated() }
    }

    required init?(coder: NSCoder) { fatalError("不支持从 nib 构造") }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    /// 把模型的变化落到窗口 frame 上。
    func applyModel() {
        alphaValue = model.opacity
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let size = model.contentSize
        var next = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height)
        if let screen {
            next = SelectionGeometry.clampedToScreen(next, screen: screen.frame,
                                                     visible: screen.visibleFrame)
        }
        // 只改尺寸不改 origin 时 setFrame 会带动画抖动，display:true 直接落位
        setFrame(next, display: true)
        pinView.needsDisplay = true
    }

    func setMagnifySign(_ provider: @escaping () -> CGFloat) {
        pinView.magnifySignProvider = provider
    }

    func wireCallbacks(destroy: @escaping () -> Void,
                       copyToClipboard: @escaping () -> Void,
                       saveToFile: @escaping () -> Void,
                       toggleAlwaysOnTop: @escaping () -> Void,
                       togglePassthrough: @escaping () -> Void) {
        pinView.destroy = destroy
        pinView.copyToClipboard = copyToClipboard
        pinView.saveToFile = saveToFile
        pinView.toggleAlwaysOnTop = toggleAlwaysOnTop
        pinView.togglePassthrough = togglePassthrough
    }

    /// 淡出 + 轻微缩小后关闭。直接 close 会让贴图"啪"地消失，手感上像没响应。
    func destroyAnimated() {
        let before = alphaValue
        let shrink = frame.insetBy(dx: frame.width * 0.02, dy: frame.height * 0.02)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            animator().alphaValue = 0
            animator().setFrame(shrink, display: true)
        }, completionHandler: { [weak self] in
            // 这两个闭包在 SDK 里是 @Sendable，而 AppKit 窗口属性是 MainActor 隔离的。
            // 完成回调实际跑在主线程，所以 assumeIsolated 是有事实依据的，
            // 不是拿来消警告的糊布 —— 直接摸 self 会被 Swift 6 判成数据竞争。
            MainActor.assumeIsolated {
                guard let self else { return }
                self.alphaValue = before
                self.orderOut(nil)
                self.onClose?(self.id)
            }
        })
    }

    // MARK: 层级 / 穿透

    func toggleAlwaysOnTop() {
        level = level == .screenSaver ? .floating : .screenSaver
    }

    func togglePassthrough() {
        ignoresMouseEvents.toggle()
        // 穿透后窗口自己收不到任何事件，只能靠 F3 全局收回；
        // 不提示的话用户会以为贴图"卡死"了
        if ignoresMouseEvents {
            pinView.toolTip = "已穿透：按 F3 收回全部贴图"
        } else {
            pinView.toolTip = "拖动移动 · 双指上下滑/捏合缩放 · 双击关闭 · 右键更多"
        }
    }

    var isPassthrough: Bool { ignoresMouseEvents }
}
