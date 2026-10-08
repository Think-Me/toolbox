import SwiftUI

struct GeneralTabView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("登录时启动 Toolbox", isOn: Binding(
                get: { model.loginItemEnabled },
                set: { _ in model.toggleLoginItem() }))
            if let err = model.loginItemError {
                Text("设置失败：\(err)")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
            Divider()
            HStack {
                Text("数据目录").frame(width: 120, alignment: .leading)
                Text(AppPaths.standard().root.path)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Button("打开") { NSWorkspace.shared.open(AppPaths.standard().root) }
                    .controlSize(.small)
            }
            HStack {
                Text("设置文件").frame(width: 120, alignment: .leading)
                Text(model.store.file.lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
            }
            Spacer()
            Text("Toolbox 0.1.0 (M0 骨架) · com.ebertwiseman.toolbox")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(20)
    }
}
