import Foundation
import ServiceManagement

public protocol LoginItemManaging: Sendable {
    func isEnabled() -> Bool
    func setEnabled(_ on: Bool) -> Result<Void, Error>
}

/// 真实现。SMAppService 要求跑在真 .app bundle 里，裸二进制会报 Operation not permitted。
public struct SMLoginItemManager: LoginItemManaging {
    public init() {}
    public func isEnabled() -> Bool { SMAppService.mainApp.status == .enabled }
    public func setEnabled(_ on: Bool) -> Result<Void, Error> {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

/// 把"注册结果"和"界面该显示什么"绑在一起，避免失败时 UI 显示成已切换的假象。
@MainActor
public final class LoginItemCoordinator {
    public struct ToggleResult: Equatable {
        public var newEnabled: Bool
        public var error: String?
    }

    private let manager: any LoginItemManaging
    public private(set) var isEnabled: Bool
    public private(set) var lastError: String?

    public init(manager: any LoginItemManaging) {
        self.manager = manager
        self.isEnabled = manager.isEnabled()
    }

    @discardableResult
    public func toggle() -> ToggleResult {
        let target = !isEnabled
        switch manager.setEnabled(target) {
        case .success:
            isEnabled = target
            lastError = nil
            return ToggleResult(newEnabled: target, error: nil)
        case .failure(let err):
            // 失败时绝不改 isEnabled：否则界面会显示一个系统里并不存在的状态
            lastError = String(describing: err)
            return ToggleResult(newEnabled: isEnabled, error: lastError)
        }
    }

    /// 用户可能直接在 系统设置 → 通用 → 登录项 里手动改，所以每次打开设置页都要回读。
    public func refresh() { isEnabled = manager.isEnabled() }
}
