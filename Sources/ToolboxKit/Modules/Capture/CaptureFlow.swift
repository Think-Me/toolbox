import AppKit

/// 把"截图结果"落到三种出口上的协调器。
///
/// 单独一层的原因：遮罩只管选区，PinManager 只管贴图，
/// 而"选完之后到底发生什么"（钉在哪、复制要不要打自写标记、存盘用哪个目录）
/// 是横跨三者的编排逻辑，散进 AppDelegate 就没法测也没法复用。
@MainActor
public final class CaptureFlow {
    private let overlay = SelectionOverlayController()
    private let pins: PinManager
    private let pasteboard: NSPasteboard
    private let settingsProvider: () -> AppSettings
    public var onMessage: ((String) -> Void)?

    public init(pins: PinManager = .shared, pasteboard: NSPasteboard = .general,
                settings: @escaping () -> AppSettings = { .default }) {
        self.pins = pins
        self.pasteboard = pasteboard
        self.settingsProvider = settings
        overlay.hidePinsForCapture = { [weak self] in
            guard let self else { return false }
            // 贴图默认参与截图；关掉该设置时才在截图前把贴图藏起来
            return !self.settingsProvider().pinsParticipateInCapture
        }
        overlay.hidePanelsForCapture = { [weak self] in
            self?.pins.hideFloatingPanels() ?? ()
        }
    }

    public var isBusy: Bool { overlay.isPresenting }

    public func startRegionCapture() {
        guard !overlay.isPresenting else { return }
        overlay.present()
        overlay.setResultHandler { [weak self] outcome in
            Task { @MainActor in self?.handle(outcome) }
        }
    }

    /// 整屏直接钉图（F2）：不走选区
    public func captureFullScreenAndPin() {
        Task { @MainActor in
            do {
                let frame = try await CaptureService().captureUnderCursor()
                let png = ImageCodec.png(frame.image) ?? Data()
                self.pin(result: .init(pngData: png,
                                        pixelSize: CGSize(width: frame.image.width,
                                                          height: frame.image.height),
                                        selectionInScreenPoints: CGRect(
                                            x: 0, y: 0,
                                            width: frame.screenFrameInPoints.width,
                                            height: frame.screenFrameInPoints.height),
                                        screenFrameInPoints: frame.screenFrameInPoints,
                                        scale: frame.scale))
            } catch {
                self.onMessage?(SelectionOverlayController.describe(
                    (error as? CaptureError) ?? .sckFailed(String(describing: error))))
            }
        }
    }

    private func handle(_ outcome: SelectionOverlayController.Outcome) {
        switch outcome {
        case .cancelled:
            break
        case .failed(let msg):
            overlay.dismiss()
            onMessage?(msg)
        case .captured(let result, let action):
            switch action {
            case .copy: copy(result: result)
            case .save: save(result: result)
            default: pin(result: result)        // 回车 = 钉图
            }
        }
    }

    // MARK: 出口

    private func pin(result: SelectionOverlayController.Result) {
        guard let image = NSImage(data: result.pngData) else {
            onMessage?("截图数据损坏，无法钉图"); return
        }
        // 必须显式设成 points 尺寸：NSImage 从 PNG 建出来时按"1 像素 = 1 point"算，
        // Retina 截图（scale=2）会让贴图比选区大一倍（实测 400×300 的选区钉成 800×600）。
        image.size = NSSize(width: result.selectionInScreenPoints.width,
                            height: result.selectionInScreenPoints.height)
        // 钉在**原选区位置**（Snipaste 行为）：选区是顶原点相对该屏，
        // 要转成 AppKit 全局左下原点坐标
        let screen = result.screenFrameInPoints
        let sel = result.selectionInScreenPoints
        let appKitOrigin = CGPoint(x: screen.minX + sel.minX,
                                   y: screen.maxY - sel.maxY)
        let size = NSSize(width: sel.width, height: sel.height)
        _ = pins.pin(image, at: CGRect(origin: appKitOrigin, size: size))
    }

    private func copy(result: SelectionOverlayController.Result) {
        pasteboard.clearContents()
        pasteboard.setData(result.pngData, forType: .png)
        // 故意**不打**自写标记：这是用户主动点的"复制"，他期望这张图出现在
        // 剪贴板历史里。自写标记只该用于"粘贴"路径（那是我们为了把内容送出去
        // 而写的，重新采一遍只会虚增计数）。
        onMessage?("已复制截图 \(Int(result.pixelSize.width))×\(Int(result.pixelSize.height))")
    }

    private func save(result: SelectionOverlayController.Result) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "截图-\(Self.stamp()).png"
        panel.level = .screenSaver
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? result.pngData.write(to: url)
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

extension PinManager {
    /// 截图前藏掉浮层面板（剪贴板面板等），但**不动贴图**——
    /// 贴图是否参与截图由设置决定，走 hideForCaptureIfConfigured。
    func hideFloatingPanels() {
        PanelPresenter.shared.dismissCurrent(reason: .explicitClose)
    }
}
