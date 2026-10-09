import AppKit
import CoreImage
import CoreVideo
import ScreenCaptureKit

public struct CapturedFrame: Sendable {
    public let image: CGImage
    public let screenFrameInPoints: CGRect
    public let scale: CGFloat

    public init(image: CGImage, screenFrameInPoints: CGRect, scale: CGFloat) {
        self.image = image
        self.screenFrameInPoints = screenFrameInPoints
        self.scale = scale
    }
}

public enum CaptureError: Error, Equatable {
    /// 未授权时 ScreenCaptureKit 可能不报错而是返回黑屏/桌面，
    /// 所以必须在入口处主动检查并抛这个错，绝不能静默返回一张黑图。
    case screenRecordingNotGranted
    case displayNotFound
    case noMainScreen
    case pixelConversionFailed
    case sckFailed(String)
}

/// 用 ScreenCaptureKit 抓整屏画面。
///
/// 为什么不用 `CGDisplayCreateImage`：macOS 14 起已弃用。
/// 也不用 `screencapture` 命令行：那样拿到的是系统选区 UI，做不了自定义遮罩与操作条。
@MainActor
public final class CaptureService {
    public init() {}

    /// 抓"光标所在的那块屏"。多屏下这是用户期待的那块。
    public func capture(screenWithCursor: NSScreen) async throws -> CapturedFrame {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.screenRecordingNotGranted }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.sckFailed(String(describing: error))
        }
        guard let display = Self.match(Self.displayID(of: screenWithCursor), in: content) else {
            throw CaptureError.displayNotFound
        }

        let scale = screenWithCursor.backingScaleFactor
        let config = SCStreamConfiguration()
        // 像素尺寸 = points × scale，取整避免半像素
        config.width = Int((screenWithCursor.frame.width * scale).rounded())
        config.height = Int((screenWithCursor.frame.height * scale).rounded())
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 1

        let filter = SCContentFilter(display: display, excludingWindows: [])
        // 这个 API 直接给 CGImage（不是 CVPixelBuffer），别照着旧文档去手写转换
        let cg: CGImage
        do {
            cg = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                            configuration: config)
        } catch {
            throw CaptureError.sckFailed(String(describing: error))
        }
        return CapturedFrame(image: cg,
                             screenFrameInPoints: screenWithCursor.frame,
                             scale: scale)
    }

    public func captureUnderCursor() async throws -> CapturedFrame {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
                ?? NSScreen.main else { throw CaptureError.noMainScreen }
        return try await capture(screenWithCursor: screen)
    }

    // MARK: - 内部

    /// NSScreen ↔ SCDisplay 的匹配用 displayID，不用 frame 比对：
    /// 两块屏分辨率相同时 frame 比较会撞车，而且缩放后 point 尺寸与 SCDisplay
    /// 的像素尺寸本来就不是同一个坐标系。
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func match(_ id: CGDirectDisplayID?, in content: SCShareableContent) -> SCDisplay? {
        guard let id else { return nil }
        return content.displays.first { $0.displayID == id }
    }

    static func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        CIContext().createCGImage(CIImage(cvPixelBuffer: buffer),
                                  from: CIImage(cvPixelBuffer: buffer).extent)
    }
}
