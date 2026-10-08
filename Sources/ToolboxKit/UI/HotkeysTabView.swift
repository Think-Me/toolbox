import SwiftUI

struct HotkeysTabView: View {
    @ObservedObject var model: AppModel

    private let labels: [(HotkeyID, String)] = [
        (.clipboard, "剪贴板历史"), (.hostsQuick, "Hosts 快速切换"),
        (.captureRegion, "区域截图"), (.captureFull, "全屏截图"),
        (.killAllPins, "关闭所有贴图"), (.openSettings, "打开设置"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(labels, id: \.0) { (id, label) in
                HStack(spacing: 10) {
                    Text(label).frame(width: 120, alignment: .leading)
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
                // 每个键位行挂一个捕获视图；只有正在录制的那一行会抢 first responder。
                .background(KeyCatcher(active: model.recordingID == id) { event in
                    model.handleRecordedKey(event)
                })
            }
            if let msg = model.recorderMessage {
                Text(msg).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            Text("提示：全局热键优先级高于前台 App 的菜单快捷键。"
                 + "若某键已被 Snipaste / SwitchHosts 等占用，需先退出对方再改绑。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(20)
    }
}
