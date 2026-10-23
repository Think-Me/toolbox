import SwiftUI

public struct SettingsRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hostsModel: HostsViewModel
    @ObservedObject var proxyModel: ProxyViewModel
    /// 打开时定位到哪一页（0 通用…5 翻译）。菜单/探针深链用。
    let initialTab: Int
    @State private var selection: Int

    public init(model: AppModel, hostsModel: HostsViewModel, proxyModel: ProxyViewModel,
                initialTab: Int = 0) {
        self.model = model
        self.hostsModel = hostsModel
        self.proxyModel = proxyModel
        self.initialTab = initialTab
        self._selection = State(initialValue: initialTab)
    }

    public var body: some View {
        TabView(selection: $selection) {
            // 权限 / 快捷键 / 通用已合成一页（用户要求）
            GeneralTabView(model: model, updater: model.softwareUpdate)
                .tabItem { Label("通用", systemImage: "gearshape") }.tag(0)
            ClipboardTabView(model: model)
                .tabItem { Label("剪贴板", systemImage: "doc.on.clipboard") }.tag(1)
            HostsTabView(hosts: hostsModel)
                .tabItem { Label("Hosts", systemImage: "network") }.tag(2)
            CaptureTabView(model: model)
                .tabItem { Label("截图与贴图", systemImage: "camera.viewfinder") }.tag(3)
            ProxyTabView(vm: proxyModel)
                .tabItem { Label("代理", systemImage: "point.topleft.down.curvedto.point.bottomright.up") }.tag(4)
            TranslationTabView(model: model)
                .tabItem { Label("翻译", systemImage: "character.book.closed") }.tag(5)
        }
        .frame(width: 560, height: 420)
        .onAppear { model.refreshPermissions(); model.refreshLoginItem() }
    }
}
