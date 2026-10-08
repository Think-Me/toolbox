import AppKit
import Carbon.HIToolbox
import Foundation

public enum PasteFailure: Error, Equatable {
    case emptyItem
    case pasteboardLocked
    case imageMissing(String)
    case keystrokePostFailed
}

public enum PasteOutcome: Equatable {
    case pasted
    /// 内容已进剪贴板，但没自动粘贴。降级不是失败：用户自己 ⌘V 一下就有。
    case copiedOnly(Degrade)
    case failed(PasteFailure)

    public enum Degrade: Equatable {
        case accessibilityNotGranted
        case targetAppUnknown
        case secureInputActive
        case timedOut
    }
}

/// 把一条历史内容写回剪贴板，并尝试粘贴回原 App。
@MainActor
public final class PasteSimulator {
    private let driver: any PasteDriving
    private let pasteboard: NSPasteboard
    private let accessibilityTrusted: () -> Bool
    private let secureInputEnabled: () -> Bool
    /// 图片条目要读 MediaStore 里的实体。用闭包注入，避免 Core 层反向依赖模块实现。
    private let imageLoader: (String) -> Data?
    private let tracker: SelfWriteTracker?

    public init(driver: any PasteDriving, pasteboard: NSPasteboard = .general,
                accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
                secureInputEnabled: @escaping () -> Bool = { IsSecureEventInputEnabled() },
                imageLoader: @escaping (String) -> Data? = { _ in nil },
                tracker: SelfWriteTracker? = nil) {
        self.driver = driver
        self.pasteboard = pasteboard
        self.accessibilityTrusted = accessibilityTrusted
        self.secureInputEnabled = secureInputEnabled
        self.imageLoader = imageLoader
        self.tracker = tracker
    }

    /// `prepare`：在**发粘贴按键之前**、写完剪贴板之后调用。
    /// 调用方必须在这里把自己的浮层关掉。原因（实测踩到）：
    /// accessory App 的 nonactivating panel 一旦成为 key window，`NSApp.isActive` 就是 true，
    /// 我们合成的 ⌘V 会被 WindowServer 投给**自己的面板**而不是目标 App，
    /// 表现就是"内容复制了但要再手动按一次 ⌘V"。
    ///
    /// 步骤顺序是契约的一部分，改动必须同步改测试：
    /// 1. 先校验内容（空内容不许清掉用户原有剪贴板）
    /// 2. 写剪贴板 + 自写标记（**必须在切前台之前**，反了会把旧内容粘出去）
    /// 3. 权限 / 目标 / Secure Input 三道闸门，任一不过就停在"只复制"
    /// 4. prepare（关掉自己的面板）→ 切前台 → 等到位 → 发 ⌘V
    public func paste(_ item: ClipboardItem, into app: NSRunningApplication?,
                      prepare: (@MainActor () -> Void)? = nil) async -> PasteOutcome {
        let payload: PastePayload
        switch item.kind {
        case .text:
            let s = item.text ?? ""
            guard !s.isEmpty else { return .failed(.emptyItem) }
            payload = .text(s)
        case .fileURLs:
            let urls = item.fileURLs ?? []
            guard !urls.isEmpty else { return .failed(.emptyItem) }
            payload = .fileURLs(urls)
        case .image:
            let sha = item.mediaSHA256 ?? ""
            guard let png = imageLoader(sha) else { return .failed(.imageMissing(sha)) }
            payload = .png(png)
        }

        guard write(payload, markerID: item.id.uuidString) else {
            return .failed(.pasteboardLocked)
        }
        if !accessibilityTrusted() { return .copiedOnly(.accessibilityNotGranted) }
        guard let app else { return .copiedOnly(.targetAppUnknown) }
        // 终端 sudo、密码框、部分 DRM 会开 Secure Input，此时合成键被系统丢弃
        if secureInputEnabled() { return .copiedOnly(.secureInputActive) }

        prepare?()
        guard await driver.activate(app) else { return .copiedOnly(.timedOut) }
        guard await driver.sendPasteKeystroke() else { return .failed(.keystrokePostFailed) }
        return .pasted
    }

    /// 返回 false 表示 pasteboard 被别的 App 锁住，写不进去。
    private func write(_ payload: PastePayload, markerID: String) -> Bool {
        // clearContents 会自己推进 changeCount，不许手工改它
        guard pasteboard.clearContents() != 0 else { return false }
        switch payload {
        case .text(let s):
            guard pasteboard.setString(s, forType: .string) else { return false }
        case .png(let data):
            guard pasteboard.setData(data, forType: .png) else { return false }
        case .fileURLs(let urls):
            guard pasteboard.writeObjects(urls as [NSURL]) else { return false }
        }
        // 自写标记：monitor 读到就跳过这条，否则我们自己的写入会被自己再采集一遍
        pasteboard.setString(markerID, forType: .ownWrite)
        // 再叠一层时间窗：目标 App 回写 pasteboard 时标记会丢，光靠标记挡不住
        tracker?.markWrite(at: Date())
        return true
    }
}

public enum PastePayload: Equatable, Sendable {
    case text(String)
    case png(Data)
    case fileURLs([URL])
}
