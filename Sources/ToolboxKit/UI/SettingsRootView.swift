import SwiftUI

public struct SettingsRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hostsModel: HostsViewModel

    public init(model: AppModel, hostsModel: HostsViewModel) {
        self.model = model
        self.hostsModel = hostsModel
    }

    public var body: some View {
        TabView {
            // 权限 / 快捷键 / 通用已合成一页（用户要求）
            GeneralTabView(model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }
            ClipboardTabView(model: model)
                .tabItem { Label("剪贴板", systemImage: "doc.on.clipboard") }
            HostsTabView(hosts: hostsModel)
                .tabItem { Label("Hosts", systemImage: "network") }
            CaptureTabView(model: model)
                .tabItem { Label("截图与贴图", systemImage: "camera.viewfinder") }
        }
        .frame(width: 560, height: 420)
        .onAppear { model.refreshPermissions(); model.refreshLoginItem() }
    }
}
