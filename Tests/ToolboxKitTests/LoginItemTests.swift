import Foundation
import Testing
@testable import ToolboxKit

// 用 class 而不是 struct：要观察 setEnabled 的副作用，值类型传进去改了外面看不见。
private final class BoxLoginItem: LoginItemManaging, @unchecked Sendable {
    var enabled: Bool
    var failOnSet = false
    init(_ e: Bool) { enabled = e }
    func isEnabled() -> Bool { enabled }
    func setEnabled(_ on: Bool) -> Result<Void, Error> {
        if failOnSet { return .failure(NSError(domain: "t", code: 1)) }
        enabled = on
        return .success(())
    }
}

@MainActor @Test func toggleFlipsStateOnSuccess() {
    let fake = BoxLoginItem(false)
    let c = LoginItemCoordinator(manager: fake)
    #expect(c.isEnabled == false)
    let r = c.toggle()
    #expect(r.newEnabled == true)
    #expect(fake.enabled == true)
    #expect(c.lastError == nil)
}

@MainActor @Test func failedToggleKeepsDisplayedStateAndSurfacesError() {
    let fake = BoxLoginItem(true)
    fake.failOnSet = true
    let c = LoginItemCoordinator(manager: fake)
    let r = c.toggle()
    #expect(r.newEnabled == true)          // 失败不许把 UI 翻成"已关闭"的假象
    #expect(r.error != nil)
    #expect(c.lastError != nil)
    #expect(fake.enabled == true)
}

@MainActor @Test func refreshReadsBackFromSystem() {
    let fake = BoxLoginItem(false)
    let c = LoginItemCoordinator(manager: fake)
    fake.enabled = true                    // 用户在系统设置里手动改
    c.refresh()
    #expect(c.isEnabled == true)
}
