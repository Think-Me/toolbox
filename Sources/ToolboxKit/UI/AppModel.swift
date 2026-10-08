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
    @Published public var loginItemEnabled: Bool
    @Published public var loginItemError: String?
    @Published public var provisioningMessage: String?

    public let store: SettingsStore
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
        recorder = HotkeyRecorderModel(initial: settings.hotkeys[id] ?? .defaultBinding(for: id))
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
            rec.escape(); recorder = rec; stopRecording(); return
        case Self.returnKey, Self.enterKey:
            if let next = rec.commit() {
                settings.hotkeys[id] = next
                recorderMessage = "已设为 \(next.displayString)，重启后仍生效"
                try? store.save(settings)
                onHotkeysChanged?(settings)
            } else {
                recorderMessage = "还没按下新键位，按 Esc 取消"
            }
            recorder = rec; stopRecording(); return
        default:
            rec.keyPressed(KeyCombo(keyCode: event.keyCode, modifierFlags: event.modifierFlags))
            recorder = rec
            if let rejected = rec.rejectedMessage {
                recorderMessage = rejected
            } else if let pending = rec.pending {
                recorderMessage = "按下 \(pending.displayString)，回车确认"
            }
        }
    }

    static let escapeKey: UInt16 = 53
    static let returnKey: UInt16 = 36
    static let enterKey: UInt16 = 76

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
