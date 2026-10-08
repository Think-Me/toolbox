import AppKit
import Foundation

/// 采集所需的外部输入。全部闭包化，这样轮询逻辑可以脱离真 pasteboard 测试。
@MainActor
public struct MonitorInputs {
    public var changeCount: () -> Int
    public var snapshot: () -> PasteboardSnapshot
    public var frontAppBundleID: () -> String?
    public var now: () -> Date

    /// 注意没有 settings：设置由 ClipboardMonitor 自己持有，两处都放会出现"读哪份"的分歧。
    public init(changeCount: @escaping () -> Int, snapshot: @escaping () -> PasteboardSnapshot,
                frontAppBundleID: @escaping () -> String?, now: @escaping () -> Date) {
        self.changeCount = changeCount; self.snapshot = snapshot
        self.frontAppBundleID = frontAppBundleID; self.now = now
    }

    public static func live() -> MonitorInputs {
        let pb = NSPasteboard.general
        return MonitorInputs(
            changeCount: { pb.changeCount },
            snapshot: { PasteboardSnapshot.read(from: pb) },
            frontAppBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            now: { Date() })
    }
}

@MainActor
public enum PollOutcome: Equatable {
    case noChange
    case ignored(CaptureDecision.IgnoreReason)
    case stored(ClipboardItem)
    case bumped(UUID)
    case failed(String)
}

/// 轮询剪贴板并落库。
///
/// 为什么是轮询：macOS 没有剪贴板变更通知 API，Maccy / Clipbook / Paste 全都这么干。
/// 单次 `changeCount` 读取远低于 0.1ms，而读内容（尤其大图）很贵，
/// 所以"没变化就一个字节都不读"是这条路径的主要性能约束，有测试盯着。
@MainActor
public final class ClipboardMonitor {
    public enum StopReason: Equatable { case userPaused, quitting }

    /// 0.3s：肉眼不觉得漏复制，开销可忽略。
    public static let pollInterval: TimeInterval = 0.3

    private let store: ClipboardStore
    private let media: MediaStore
    private let inputs: MonitorInputs
    private let settingsProvider: () -> AppSettings
    private var lastChangeCount = -1
    private var timer: Timer?
    private var paused = false

    public private(set) var stopReason: StopReason?
    public var onChange: ((ClipboardItem) -> Void)?
    public var isRunning: Bool { timer != nil }

    public init(store: ClipboardStore, media: MediaStore, inputs: MonitorInputs,
                settings: @escaping () -> AppSettings) {
        self.store = store; self.media = media; self.inputs = inputs
        self.settingsProvider = settings
    }

    public func start() {
        paused = false
        stopReason = nil
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in _ = await self.pollOnce() }
        }
        // .common 模式：菜单打开、拖拽进行时也要继续采集，否则用户一开菜单就漏复制
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop(reason: StopReason) {
        timer?.invalidate()
        timer = nil
        stopReason = reason
        if reason == .userPaused { paused = true }
    }

    public func storedCount() async -> Int { (try? await store.count()) ?? 0 }

    /// 一次轮询。单独暴露出来是为了能在测试里手动驱动，不必等真 Timer。
    @discardableResult
    public func pollOnce() async -> PollOutcome {
        if paused {
            // 暂停期间仍要跟上 changeCount，否则恢复的瞬间会把暂停期间的旧内容补记进来
            lastChangeCount = inputs.changeCount()
            return .ignored(.paused)
        }
        let cc = inputs.changeCount()
        guard cc != lastChangeCount else { return .noChange }
        lastChangeCount = cc

        let snapshot = inputs.snapshot()
        let candidate = PasteboardNormalizer.normalize(snapshot)
        let top = (try? await store.recent(limit: 1))?.first
        let decision = ClipboardFilter.decide(CaptureInput(
            types: snapshot.types, ownWriteMarker: snapshot.ownWriteMarker,
            candidate: candidate, currentTop: top,
            frontAppBundleID: inputs.frontAppBundleID(),
            paused: false, settings: settingsProvider(), now: inputs.now()))

        switch decision {
        case .ignore(.sameAsTop):
            guard let top else { return .ignored(.sameAsTop) }
            do {
                try await store.bump(id: top.id, at: inputs.now())
                return .bumped(top.id)
            } catch {
                return .failed(error.localizedDescription)
            }
        case .ignore(let reason):
            return .ignored(reason)
        case .accept(let content):
            do {
                let item = try await makeItem(from: content)
                try await store.insert(item)
                let trimmed = try await store.trim(to: settingsProvider().clipboardCapacity)
                if !trimmed.deletedMediaSHAs.isEmpty {
                    _ = try media.garbageCollect(liveSHAs: Set(await store.allMediaSHAs()))
                }
                onChange?(item)
                return .stored(item)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    private func makeItem(from c: CapturedContent) async throws -> ClipboardItem {
        let bundleID = inputs.frontAppBundleID()
        // NSRunningApplication 没有 bundleIdentifier 初始化器，只能在已运行的进程里找
        let appName = bundleID.flatMap { id in
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }?.localizedName
        }
        let now = inputs.now()
        switch c.kind {
        case .text:
            return ClipboardItem(text: c.text ?? "", sourceBundleID: bundleID,
                                 sourceAppName: appName, at: now)
        case .fileURLs:
            return ClipboardItem(fileURLs: c.fileURLs, sourceBundleID: bundleID,
                                 sourceAppName: appName, at: now)
        case .image:
            let png = c.pngData ?? Data()
            let sha = try media.store(png: png)
            return ClipboardItem(imagePNG: png, sha256: sha, pixelSize: c.pixelSize,
                                 sourceBundleID: bundleID, sourceAppName: appName, at: now)
        }
    }
}
