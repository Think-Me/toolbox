import SwiftUI

struct PermissionsTabView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.permissionRows, id: \.permission) { row in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(color(for: row.state))
                        .frame(width: 10, height: 10)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: row.permission)).font(.system(size: 13, weight: .medium))
                        Text(row.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let action = row.actionTitle {
                        Button(action) { model.act(on: row) }
                            .controlSize(.small)
                    }
                }
                Divider()
            }
            if let msg = model.provisioningMessage {
                Text(msg).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("重新探测") { model.refreshPermissions() }
                Text("屏幕录制授权后需重启 Toolbox 才生效")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private func color(for s: PermissionState) -> Color {
        switch s {
        case .granted: return .green
        case .denied:  return .orange
        case .unknown: return .gray
        }
    }

    private func title(for p: Permission) -> String {
        switch p {
        case .accessibility:   return "辅助功能"
        case .screenRecording: return "屏幕录制"
        case .hostsWritable:   return "写入 /etc/hosts"
        case .dnsFlush:        return "刷新 DNS 缓存"
        }
    }
}
