import SwiftUI

/// 设置页「通用」。原来是 权限 / 快捷键 / 通用 三个 tab，按用户要求合成一页：
/// 这三段的共同点是"这个 App 能不能用、怎么用起来"，拆开反而让人到处翻。
/// 560×420 放不下三段内容，所以整页纵向滚动。
struct GeneralTabView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                section("权限") { permissionsSection }
                Divider().padding(.horizontal, 20)
                section("快捷键") { hotkeysSection }
                Divider().padding(.horizontal, 20)
                section("通用") { generalSection }
            }
        }
        .frame(width: 560, height: 420)
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    // MARK: 权限

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.permissionRows, id: \.permission) { row in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(color(for: row.state))
                        .frame(width: 10, height: 10)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: row.permission))
                            .font(.system(size: 13, weight: .medium))
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
        }
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

    // MARK: 快捷键

    private var hotkeysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(HotkeyID.allCases, id: \.self) { id in
                HStack(spacing: 10) {
                    Text(id.label).frame(width: 120, alignment: .leading)
                    Text(model.settings.hotkeys[id]?.displayString ?? "未设置")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 90, alignment: .leading)
                    Spacer()
                    if model.recordingID == id {
                        Text("等待按键… (Esc 取消)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("取消") { model.stopRecording() }.controlSize(.small)
                    } else {
                        Button("录制") { model.beginRecording(id) }.controlSize(.small)
                    }
                }
            }
            if let msg = model.recorderMessage {
                // 冲突/非法键位用红色，普通提示用灰色 ——
                // 用户要一眼分出"这次没成功"和"只是在提示"
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundStyle(model.recorderIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("提示：全局热键优先级高于前台 App 的菜单快捷键。"
                 + "若某键已被 Snipaste / SwitchHosts 等占用，录制时会直接拒绝。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 通用

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("登录时启动 Toolbox", isOn: Binding(
                get: { model.loginItemEnabled },
                set: { _ in model.toggleLoginItem() }))
            if let err = model.loginItemError {
                Text("设置失败：\(err)")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
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
        }
    }
}
