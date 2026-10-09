import AppKit

/// 所有贴图的总管。
///
/// 刻意做成"能被别模块调用"的最小面（Clipboard 的 ⌘E 就靠它），
/// 反向依赖禁止：Capture 不认识 Clipboard。
@MainActor
public final class PinManager {
    public static let shared = PinManager()

    public private(set) var pins: [PinWindow] = []
    /// 滚轮方向、缩放上下限等，由入口注入，避免这里去读全局设置
    public var settingsProvider: () -> AppSettings = { .default }
    public var magnifySignProvider: () -> CGFloat = { 1 }

    private init() {}

    public var pinCount: Int { pins.count }

    /// 在指定的 AppKit 屏幕矩形处钉一张图。
    @discardableResult
    public func pin(_ image: NSImage, at screenFrame: CGRect) -> PinWindow {
        let s = settingsProvider()
        let model = PinZoomModel(intrinsic: image.size, zoom: 1,
                                 minZoom: s.pinMinZoom, maxZoom: s.pinMaxZoom)
        let window = PinWindow(image: image, initialModel: model, screenFrame: screenFrame)
        window.setMagnifySign(magnifySignProvider)
        let id = window.id
        window.wireCallbacks(
            destroy: { [weak self] in self?.destroy(window) },
            copyToClipboard: { [weak self] in self?.copyToClipboard(window) },
            saveToFile: { [weak self] in self?.save(window) },
            toggleAlwaysOnTop: { window.toggleAlwaysOnTop() },
            togglePassthrough: { window.togglePassthrough() })
        window.onClose = { [weak self] _ in self?.remove(id) }
        pins.append(window)
        window.orderFrontRegardless()
        return window
    }

    /// 从 PNG 数据钉图（剪贴板图片条目、截图结果都走这里）
    @discardableResult
    public func pin(pngData: Data, at screenFrame: CGRect) -> PinWindow? {
        guard let image = NSImage(data: pngData) else { return nil }
        return pin(image, at: screenFrame)
    }

    public func destroy(_ window: PinWindow) {
        window.destroyAnimated()
    }

    private func remove(_ id: UUID) {
        pins.removeAll { $0.id == id }
    }

    /// `F3`：穿透模式下这是唯一的救急出口，所以必须无条件能关掉所有贴图。
    public func closeAll() {
        for w in pins where w.isVisible { w.destroyAnimated() }
    }

    /// 截图前调用。贴图默认**参与**截图（用户可能就是想把贴图截进去），
    /// 设置反过来时才隐藏。
    public func hideForCaptureIfConfigured() {
        guard !settingsProvider().pinsParticipateInCapture else { return }
        for w in pins where w.isVisible { w.orderOut(nil) }
    }

    public func restoreAfterCapture() {
        guard !settingsProvider().pinsParticipateInCapture else { return }
        for w in pins { w.orderFront(nil) }
    }

    // MARK: 单张操作

    public func copyToClipboard(_ window: PinWindow) {
        guard let image = window.cgImage else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        guard let png = ImageCodec.png(image) else { return }
        pb.setData(png, forType: .png)
        // 打自写标记：否则这张图会被自己的 monitor 再采一遍，历史里多一条
        pb.setString("pin-\(window.id.uuidString)", forType: .ownWrite)
    }

    public func save(_ window: PinWindow) {
        guard let image = window.cgImage else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "贴图-\(Self.timestamp()).png"
        panel.level = .floating          // 别被贴在桌面上的贴图盖住
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = ImageCodec.png(image) else { return }
            try? data.write(to: url)
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

extension PinWindow {
    /// 原始分辨率的 CGImage，供复制与存盘使用。
    public var cgImage: CGImage? {
        var rect = NSRect(origin: .zero, size: sourceImage.size)
        return sourceImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
