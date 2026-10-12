import AppKit
import Testing
@testable import ToolboxKit

/// 热键闸门的回归测试。
///
/// 原先的设计是"打字时把 6 个全局热键注销、编辑结束后重注册"，
/// 结果任何一条忘记恢复的路径都会让热键**永久失灵且不重启不好**
/// （实测踩了两次：点钉图收口、输入框没拿到焦点）。
/// 现在改成 weak 宿主闸门：没有需要恢复的状态，所以不可能漏。
/// 这些测试也因此不再依赖 Carbon，任何环境都真的在跑。
@MainActor
@Test func gateFollowsHostLifetime() {
    final class Host {}
    let center = HotkeyCenter()
    #expect(center.isIgnoringHotkeysForTextInput == false)

    let host = Host()
    center.textEditingHost = host
    #expect(center.isIgnoringHotkeysForTextInput == true)

    center.textEditingHost = nil
    #expect(center.isIgnoringHotkeysForTextInput == false)
}

@MainActor
@Test func gateClearsItselfWhenHostDies() {
    // 这条是整个改动的意义：宿主（遮罩视图）被释放，闸门自动打开。
    // 不需要谁去"记得恢复"
    let center = HotkeyCenter()
    do {
        let host = NSObject()
        center.textEditingHost = host
        #expect(center.isIgnoringHotkeysForTextInput == true)
    }
    #expect(center.isIgnoringHotkeysForTextInput == false)
}

@MainActor
@Test func dispatchIsSwallowedWhileGated() {
    // 直接验证"回调真的没被调用"，而不是只看标志位
    final class Counter { var fired = 0 }
    final class Host {}
    let center = HotkeyCenter()
    let counter = Counter()
    let combo = KeyCombo(keyCode: KeyCombo.ansiA, carbonModifiers: KeyCombo.control)
    // 真注册需要事件处理器装得上；装不上的环境（无 GUI CI）跳过这条，
    // 前两条不依赖 Carbon，任何环境都在真跑
    guard center.register(.captureRegion, combo, handler: { counter.fired += 1 }) else { return }

    let host = Host()                 // 必须持有：weak 不会帮你留住临时对象
    center.textEditingHost = host
    center.dispatchForTesting(.captureRegion)
    #expect(counter.fired == 0)

    center.textEditingHost = nil
    center.dispatchForTesting(.captureRegion)
    #expect(counter.fired == 1)
    _ = host
}
