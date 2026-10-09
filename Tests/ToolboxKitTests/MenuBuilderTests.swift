import Foundation
import Testing
@testable import ToolboxKit

@Test func topLevelOrderMatchesSpec() {
    let items = MenuBuilder.items(settings: .default, recording: true, loginItemEnabled: false)
    let titles = items.filter { !$0.isSeparator }.map(\.title)
    #expect(titles.prefix(3) == ["剪贴板历史", "Hosts 规则", "区域截图"])
    #expect(titles.contains("全屏截图"))
    #expect(titles.contains("关闭所有贴图"))
    #expect(titles.last == "退出 Toolbox")
    #expect(titles.contains("设置与快捷键…"))
}

@Test func separatorsPresentBetweenGroups() {
    let items = MenuBuilder.items(settings: .default, recording: true, loginItemEnabled: false)
    let seps = items.filter(\.isSeparator)
    #expect(seps.count >= 2)   // 功能组后、以及退出前
}

@Test func pauseItemCheckStateIsInvertedFromRecording() {
    let recording = MenuBuilder.items(settings: .default, recording: true, loginItemEnabled: false)
    let paused = MenuBuilder.items(settings: .default, recording: false, loginItemEnabled: false)
    let a = recording.first { $0.title == "暂停剪贴板记录" }!
    let b = paused.first { $0.title == "暂停剪贴板记录" }!
    #expect(a.checked == false)     // 正在记录 → "暂停"未勾选
    #expect(b.checked == true)      // 已暂停 → 勾选
}

@Test func letterHotkeyMapsToCharacterAndCarbonMask() {
    let items = MenuBuilder.items(settings: .default, recording: true, loginItemEnabled: false)
    let capture = items.first { $0.title == "区域截图" }!
    #expect(capture.keyEquivalent == "a")
    #expect(capture.keyEquivalentMask == (KeyCombo.control | KeyCombo.cmd))
}

@Test func functionKeyHotkeyHasNoCharacterEquivalent() {
    // F2/F3 没有可打印字符。若把 "f2" 当 keyEquivalent 塞进菜单，
    // 会变成"按 f 就能触发"的幽灵快捷键，所以必须是 nil。
    let items = MenuBuilder.items(settings: .default, recording: true, loginItemEnabled: false)
    #expect(items.first { $0.title == "全屏截图" }!.keyEquivalent == nil)
    #expect(items.first { $0.title == "关闭所有贴图" }!.keyEquivalent == nil)
}

@Test func hostsItemDeclaresSubmenuWithExplicitPlaceholder() {
    let items = MenuBuilder.items(settings: .default, recording: true, loginItemEnabled: false)
    let hosts = items.first { $0.title == "Hosts 规则" }!
    #expect(hosts.children.isEmpty == false)          // 声明了子菜单就必须有内容，不许空数组冒充
    #expect(hosts.children[0].action == .hostsManagementToggle)
}

@Test func loginItemRowCarriesCurrentState() {
    let off = MenuBuilder.items(settings: .default, recording: true, loginItemEnabled: false)
    let on = MenuBuilder.items(settings: .default, recording: true, loginItemEnabled: true)
    #expect(off.first { $0.title == "登录时启动" }!.checked == false)
    #expect(on.first { $0.title == "登录时启动" }!.checked == true)
}

@Test func everyActionIsRoutableOrExplicitlyDisabled() {
    let items = MenuBuilder.items(settings: .default, recording: true, loginItemEnabled: false)
    for it in items where !it.isSeparator {
        switch it.action {
        case .hotkey, .togglePause, .openPermissions, .openSettings,
             .toggleLoginItem, .hostsToggle, .hostsManagementToggle,
             .quit, .separator, .disabledPlaceholder:
            break
        }
    }
    // 五个业务热键必须都在菜单里出现，否则改绑后菜单与热键会不一致
    let hotkeys = Set(items.compactMap { spec -> HotkeyID? in
        if case .hotkey(let id) = spec.action { return id } else { return nil }
    })
    #expect(hotkeys == Set(HotkeyID.allCases))
}

@Test func hostsSubmenuListsRealRulesWithCheckState() {
    let idA = UUID(), idB = UUID()
    let snap = HostsMenuSnapshot(managementOn: true, rows: [
        .init(id: idA, group: "公司", name: "内网", enabled: true),
        .init(id: idB, group: "个人", name: "测试", enabled: false),
    ])
    let items = MenuBuilder.items(settings: .default, recording: true,
                                  loginItemEnabled: false, hosts: snap)
    let children = items.first { $0.title == "Hosts 规则" }!.children
    #expect(children[0].action == .hostsManagementToggle)
    #expect(children[0].checked == true)
    let toggles = children.compactMap { spec -> UUID? in
        if case .hostsToggle(let id) = spec.action { return id } else { return nil }
    }
    #expect(toggles == [idA, idB])
    #expect(children.first { $0.title == "内网" }?.checked == true)
    #expect(children.first { $0.title == "测试" }?.checked == false)
}

@Test func hostsSubmenuHidesRulesWhenManagementOff() {
    let snap = HostsMenuSnapshot(managementOn: false, rows: [
        .init(id: UUID(), group: "g", name: "r", enabled: true)])
    let children = MenuBuilder.hostsSubmenu(snap)
    #expect(children.count == 1)
    #expect(children[0].title == "Hosts 托管：关")
}

@Test func hostsSubmenuWithNoRulesTellsUserWhatToDo() {
    let children = MenuBuilder.hostsSubmenu(.empty)
    #expect(children.count == 2)
    #expect(children[1].title.contains("新建"))
    #expect(children[1].action == .disabledPlaceholder)
}
