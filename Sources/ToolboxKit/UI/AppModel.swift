// @preconcurrency：SDK 把 addLocalMonitorForEvents 的 handler 标成 @Sendable，
// 但 NSEvent 不 conform Sendable —— 这是系统框架的注解缺陷，不是我们的代码问题。
@preconcurrency import AppKit
import SwiftUI

/// 设置窗与浮层共用的状态源。
/// 之所以自己拿一个事件 monitor 而不是每个录制按钮装一个 NSView：
/// 六行同时只能有一行在录，集中管理才不会出现"两行都在抢键盘"。
@MainActor
public final class AppModel: ObservableObject {
    @Published public var settings: AppSettings
    @Published public var permissionRows: [PermissionRow]
    @Published public var recordingID: HotkeyID?
    @Published public var recorderMessage: String?
    /// recorderMessage 是"这次没成功"（冲突/非法键位）还是普通进度提示。
    /// 不分的话，红色的错误和灰色的提示混在一起，用户看不出有没有改上
    @Published public var recorderIsError = false
    @Published public var loginItemEnabled: Bool
    @Published public var loginItemError: String?
    @Published public var provisioningMessage: String?

    public let store: SettingsStore
    /// 剪贴板设置页要读写历史，由 AppDelegate 在开库后注入。
    /// 用可选是因为设置窗可能在数据库就绪前就被打开。
    public var clipboardStore: ClipboardStore?
    public var mediaStore: MediaStore?
    @Published public var storedItemCount = 0
    @Published public var mediaBytes = 0
    public let permissions: PermissionCenter
    private let loginItem: LoginItemCoordinator
    /// 改完键位必须让调用方重新注册，否则设置界面显示新键、实际生效的还是旧键。
    /// AppModel 不认识 HotkeyCenter，用回调把方向保持成 UI → Core 单向。
    public var onHotkeysChanged: (@MainActor (AppSettings) -> Void)?

    private var recorder: HotkeyRecorderModel?

    public init(settings: AppSettings, store: SettingsStore,
                permissions: PermissionCenter,
                loginItem: LoginItemCoordinator) {
        self.settings = settings
        self.store = store
        self.permissions = permissions
        self.loginItem = loginItem
        self.loginItemEnabled = loginItem.isEnabled
        self.permissionRows = permissions.snapshot()
    }

    // MARK: 权限

    public func refreshPermissions() {
        permissionRows = permissions.snapshot()
    }

    public var isRecording: Bool { recordingID != nil }

    public func act(on row: PermissionRow) {
        switch row.permission {
        case .accessibility:   permissions.requestAccessibility()
        case .screenRecording: permissions.requestScreenRecording()
        case .hostsWritable:
            provision(.hostsGroupWritable)
        case .dnsFlush:
            provision(.dnsSudoers)
        }
        refreshPermissions()
    }

    /// 一次性系统授权。跑在后台队列：AppleScript 会阻塞等用户输密码。
    private func provision(_ step: Provisioning.Step) {
        provisioningMessage = "等待管理员授权…"
        Task.detached(priority: .userInitiated) {
            let result = await Provisioning.run(step)
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    self.provisioningMessage = "授权完成"
                case .failure(.cancelled):
                    self.provisioningMessage = "已取消授权"
                case .failure(.validationFailed(let m)), .failure(.installFailed(let m)),
                     .failure(.notEffective(let m)):
                    self.provisioningMessage = m
                }
                self.refreshPermissions()
            }
        }
    }

    // MARK: 快捷键录制

    public func beginRecording(_ id: HotkeyID) {
        stopRecording()
        recordingID = id
        recorderMessage = nil
        recorderIsError = false
        var rec = HotkeyRecorderModel(initial: settings.hotkeys[id] ?? .defaultBinding(for: id))
        // 必须调用模型自己的 beginRecording：它的 keyPressed 第一行是
        // `guard isRecording else { return }`，漏了这步就是"进入录制态但按什么都没反应"。
        rec.beginRecording()
        recorder = rec
    }

    public func stopRecording() {
        recorder = nil
        recordingID = nil
    }

    /// 由录制视图直接调用（视图是 first responder，事件本来就在主线程）。
    /// 不用 `NSEvent.addLocalMonitorForEvents`：录制只在设置窗口有焦点时发生，
    /// 装全局 monitor 会抢走整个 App 的键盘，而且它的 handler 被 SDK 标成 @Sendable，
    /// 而 NSEvent 不 conform Sendable，Swift 6 下连编译都过不去。
    public func handleRecordedKey(_ event: NSEvent) {
        guard var rec = recorder, let id = recordingID else { return }
        switch event.keyCode {
        case Self.escapeKey:
            rec.escape(); recorder = rec
            recorderMessage = nil
            recorderIsError = false
            stopRecording(); return
        case Self.returnKey, Self.enterKey:
            if let next = rec.commit() {
                // 落盘**之前**先判冲突：撞了就拒绝，保持原键位不变
                if let conflict = HotkeyConflict.detect(
                    proposed: next, for: id, bindings: settings.hotkeys,
                    probeOccupied: { HotkeyCenter.shared.isOccupiedByOtherApp($0) }) {
                    recorderMessage = conflict
                    recorderIsError = true
                    recorder = rec
                    stopRecording()
                    return
                }
                settings.hotkeys[id] = next
                recorderMessage = "已设为 \(next.displayString)，重启后仍生效"
                recorderIsError = false
                try? store.save(settings)
                onHotkeysChanged?(settings)
            } else {
                recorderMessage = "还没按下新键位，按 Esc 取消"
                recorderIsError = false
            }
            recorder = rec; stopRecording(); return
        default:
            rec.keyPressed(KeyCombo(keyCode: event.keyCode, modifierFlags: event.modifierFlags))
            recorder = rec
            if let rejected = rec.rejectedMessage {
                recorderMessage = rejected
                recorderIsError = true
            } else if let pending = rec.pending {
                recorderMessage = "按下 \(pending.displayString)，回车确认"
                recorderIsError = false
            }
        }
    }

    static let escapeKey: UInt16 = 53
    static let returnKey: UInt16 = 36
    static let enterKey: UInt16 = 76

    // MARK: 剪贴板设置

    public var mediaSizeLabel: String {
        let mb = Double(mediaBytes) / 1_048_576
        if mb < 1 { return "\(mediaBytes / 1024) KB" }
        return String(format: "%.1f MB", mb)
    }

    public func refreshClipboardStats() {
        guard let store = clipboardStore, let media = mediaStore else { return }
        Task { @MainActor in
            self.storedItemCount = (try? await store.count()) ?? 0
            self.mediaBytes = (try? media.totalBytes()) ?? 0
        }
    }

    public func setCapacity(_ n: Int) {
        settings.clipboardCapacity = n
        persist()
    }

    /// 调小容量后立刻淘汰，不用等下一次复制。
    public func applyCapacityTrim() async {
        guard let store = clipboardStore else { return }
        _ = try? await store.trim(to: settings.clipboardCapacity)
        if let media = mediaStore {
            _ = try? media.garbageCollect(liveSHAs: Set((try? await store.allMediaSHAs()) ?? []))
        }
        refreshClipboardStats()
    }

    public func setRecordAutoGenerated(_ on: Bool) {
        settings.recordAutoGenerated = on
        persist()
    }

    public func addBlockedApp(_ id: String) {
        guard !settings.blockedApps.contains(id) else { return }
        settings.blockedApps.append(id)
        persist()
    }

    public func removeBlockedApp(_ id: String) {
        settings.blockedApps.removeAll { $0 == id }
        persist()
    }

    public func clearHistory() {
        guard let store = clipboardStore else { return }
        Task { @MainActor in
            let shas = (try? await store.clearAll()) ?? []
            if let media = mediaStore {
                _ = try? media.garbageCollect(liveSHAs: Set((try? await store.allMediaSHAs()) ?? []))
            }
            _ = shas
            refreshClipboardStats()
        }
    }

    private func persist() {
        try? store.save(settings)
    }

    // MARK: 截图与贴图设置

    public func setScrollZoomDirection(_ d: AppSettings.ZoomDirection) {
        settings.scrollZoomDirection = d
        persist()
    }

    public func resetZoomRange() {
        settings.pinMinZoom = AppSettings.default.pinMinZoom
        settings.pinMaxZoom = AppSettings.default.pinMaxZoom
        persist()
    }

    public func setSnapSelectionToEdges(_ on: Bool) {
        settings.snapSelectionToEdges = on
        persist()
    }

    public func setShowMagnifier(_ on: Bool) {
        settings.showMagnifier = on
        persist()
    }

    public func setAnnotationToolbarEnabled(_ on: Bool) {
        settings.annotationToolbarEnabled = on
        persist()
    }

    public func setAnnotationDefaultColorHex(_ hex: String) {
        // 一律吸附到调色板里的颜色再存：存进去的值必须能被工具条原样显示出来
        settings.annotationDefaultColorHex = AnnotationPalette.nearestColor(hex: hex).hexString
        persist()
    }

    public func setAnnotationDefaultLineWidth(_ w: Double) {
        settings.annotationDefaultLineWidth = Double(AnnotationPalette.nearestLineWidth(w))
        persist()
    }

    public func setClipboardVisibleRows(_ n: Int) {
        settings.clipboardVisibleRows = ClipboardPanelGeometry.clampedRows(n)
        persist()
    }

    public func setPinsParticipateInCapture(_ on: Bool) {
        settings.pinsParticipateInCapture = on
        persist()
    }

    // MARK: 登录项

    public func toggleLoginItem() {
        let r = loginItem.toggle()
        loginItemEnabled = r.newEnabled
        loginItemError = r.error
    }

    public func refreshLoginItem() {
        loginItem.refresh()
        loginItemEnabled = loginItem.isEnabled
    }
}

extension KeyCombo {
    /// 设置里缺键位时的兜底，和 AppSettings.default 保持同一份口径。
    static func defaultBinding(for id: HotkeyID) -> KeyCombo {
        AppSettings.default.hotkeys[id] ?? KeyCombo(keyCode: 0, carbonModifiers: cmd)
    }
}
