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
            PermissionsTabView(model: model)
                .tabItem { Label("权限", systemImage: "lock.shield") }
            HotkeysTabView(model: model)
                .tabItem { Label("快捷键", systemImage: "keyboard") }
            GeneralTabView(model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }
            // 以下三页是明确标注的延后项，不是空白占位：写清哪一版实现。
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

struct ComingSoonView: View {
    let title: String
    let milestone: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(title)设置将在 \(milestone) 实现")
                .font(.headline)
            ForEach(lines, id: \.self) { Text("· \($0)").foregroundStyle(.secondary) }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }
}
