import AppKit

/// 遮罩窗口。
///
/// 必须覆写 canBecomeKey：`.borderless` 窗口默认返回 false，
/// 于是 `makeKeyAndOrderFront` 之后它拿不到键盘焦点，
/// 表现就是"能拖选区、但回车/Esc/方向键全都没反应"（M0 在浮层上踩过同一个坑）。
@MainActor
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 截图遮罩的总管：抓屏 → 铺一个覆盖整屏的窗口 → 把结果分发出去。
@MainActor
public final class SelectionOverlayController {
    public struct Result: Sendable {
        public let pngData: Data
        public let pixelSize: CGSize
        /// 选区在该屏上的 points 矩形（顶原点），用于把贴图放回原位
        public let selectionInScreenPoints: CGRect
        public let screenFrameInPoints: CGRect
        public let scale: CGFloat
    }

    public enum Outcome: Sendable {
        /// 带上用户点的按钮：复制 / 钉图 / 存盘 三条出口的后续动作完全不同
        case captured(Result, CaptureCommit)
        case cancelled
        case failed(String)
    }

    private var window: NSWindow?
    private var view: SelectionView?
    private var frame: CapturedFrame?
    private var completion: ((Outcome) -> Void)?

    /// 由 CaptureFlow 注入。不用闭包属性是因为要在 present 之前就能设。
    public func setResultHandler(_ handler: @escaping @MainActor (Outcome) -> Void) {
        self.completion = handler
    }
    private let capture = CaptureService()
    public var hidePinsForCapture: () -> Bool = { false }
    public var hidePanelsForCapture: () -> Void = {}

    public init() {}

    /// 由 CaptureFlow 注入：吸附/放大镜开关 + 窗口枚举来源。
    /// 用闭包而不是直接读设置单例，遮罩层就不绑死在 AppSettings 上。
    public var snapEnabledProvider: () -> Bool = { true }
    public var magnifierEnabledProvider: () -> Bool = { true }
    public var windowProvider: any WindowCandidateProviding = CGWindowCandidateProvider()

    public var isPresenting: Bool { window != nil }

    public func present() {
        guard window == nil else { return }
        hidePanelsForCapture()
        let shouldHidePins = hidePinsForCapture()
        Task { @MainActor in
            do {
                let frame = try await self.capture.captureUnderCursor()
                self.frame = frame
                let image = NSImage(cgImage: frame.image,
                                    size: NSSize(width: frame.screenFrameInPoints.width,
                                                 height: frame.screenFrameInPoints.height))
                let v = SelectionView(screenImage: image, cgImage: frame.image)
                v.screenScale = frame.scale
                v.snapEnabled = snapEnabledProvider()
                v.magnifierEnabled = magnifierEnabledProvider()
                // 窗口列表要在遮罩出现之后再取：provider 按 pid 排除自己，
                // 所以拿到的是用户真正能框的那些窗口。
                // 不需要再去找 NSScreen 对象——CapturedFrame 已经带了该屏的 AppKit frame。
                let primaryHeight = NSScreen.screens.first?.frame.height
                    ?? frame.screenFrameInPoints.height
                if let geometry = ScreenGeometry(appKitFrame: frame.screenFrameInPoints,
                                                 primaryHeight: primaryHeight) {
                    v.windowCandidates = windowProvider.candidates(
                        for: geometry,
                        excluding: ProcessInfo.processInfo.processIdentifier)
                    if CommandLine.arguments.contains("--overlay-eventlog") {
                        let summary = v.windowCandidates.prefix(6)
                            .map { "\($0.origin.x),\($0.origin.y) \($0.width)x\($0.height)" }
                            .joined(separator: " | ")
                        FileHandle.standardError.write(
                            "CANDIDATES \(v.windowCandidates.count) \(summary)\n"
                                .data(using: .utf8)!)
                    }
                }
                let w = OverlayWindow(contentRect: frame.screenFrameInPoints,
                                      styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                w.level = .screenSaver
                w.isOpaque = true
                w.backgroundColor = .black
                w.ignoresMouseEvents = false
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                w.contentView = v
                v.onCommit = { [weak self] kind in self?.handle(kind) }
                self.window = w
                self.view = v
                w.makeKeyAndOrderFront(nil)
                w.makeFirstResponder(v)
            } catch let e as CaptureError {
                self.finish(.failed(Self.describe(e)))
            } catch {
                self.finish(.failed(String(describing: error)))
            }
            _ = shouldHidePins
        }
    }

    public func dismiss() {
        window?.orderOut(nil)
        window = nil
        view = nil
        frame = nil
    }

    static func describe(_ e: CaptureError) -> String {
        switch e {
        case .screenRecordingNotGranted:
            return "未授予屏幕录制权限：请到 系统设置 → 隐私与安全性 → 屏幕录制 打开 Toolbox，然后重启 App"
        case .displayNotFound: return "找不到当前显示器，请重连屏幕后重试"
        case .noMainScreen: return "没有可用显示器"
        case .pixelConversionFailed: return "画面转换失败"
        case .sckFailed(let m): return "截图失败：\(m)"
        }
    }

    // MARK: 分发

    private func handle(_ kind: CaptureCommit) {
        switch kind {
        case .cancel:
            finish(.cancelled)
        case .reshot:
            dismiss()
            present()
        case .pin(let sel), .copy(let sel), .save(let sel):
            guard let result = crop(selection: sel) else {
                finish(.failed("裁剪失败：选区超出画面范围"))
                return
            }
            finish(.captured(result, kind))
        }
    }

    private func finish(_ outcome: Outcome) {
        let cb = completion
        completion = nil
        if outcome.isTerminalForUI { dismiss() }
        cb?(outcome)
    }

    private func crop(selection: CGRect) -> Result? {
        guard let frame else { return nil }
        let px = SelectionGeometry.flippedRectToPixels(selection, scale: frame.scale)
        guard let cropped = ImageCodec.crop(frame.image, pixelRect: px),
              let png = ImageCodec.png(cropped) else { return nil }
        return Result(pngData: png,
                      pixelSize: CGSize(width: cropped.width, height: cropped.height),
                      selectionInScreenPoints: selection,
                      screenFrameInPoints: frame.screenFrameInPoints,
                      scale: frame.scale)
    }
}

extension SelectionOverlayController.Outcome {
    /// 拿到结果后也要收掉遮罩：否则半透明的全屏遮罩会一直挡在桌面上，
    /// 而存盘面板是独立窗口，不需要遮罩继续存在。
    var isTerminalForUI: Bool { true }
}
