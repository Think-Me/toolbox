import SwiftUI

/// 截图与贴图设置页。
struct CaptureTabView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("贴图缩放方向", selection: Binding(
                get: { model.settings.scrollZoomDirection },
                set: { model.setScrollZoomDirection($0) })) {
                Text("双指上滑放大").tag(AppSettings.ZoomDirection.upMagnifies)
                Text("双指上滑缩小").tag(AppSettings.ZoomDirection.downMagnifies)
            }
            .pickerStyle(.radioGroup)

            HStack {
                Text("缩放范围").frame(width: 110, alignment: .leading)
                Text("\(String(format: "%.1f", model.settings.pinMinZoom))× – \(String(format: "%.0f", model.settings.pinMaxZoom))×")
                Spacer()
                Button("恢复默认 (0.2×–8×)") { model.resetZoomRange() }
                    .controlSize(.small)
            }

            Toggle("截图时包含已有贴图", isOn: Binding(
                get: { model.settings.pinsParticipateInCapture },
                set: { model.setPinsParticipateInCapture($0) }))
            Text("开启后，新截图会把桌面上已有的贴图一起截进去；关闭则截图前临时藏起所有贴图。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("选区边缘吸附到窗口与屏幕边界", isOn: Binding(
                get: { model.settings.snapSelectionToEdges },
                set: { model.setSnapSelectionToEdges($0) }))
            Toggle("截图时显示像素放大镜与取色", isOn: Binding(
                get: { model.settings.showMagnifier },
                set: { model.setShowMagnifier($0) }))

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("贴图快捷键").font(.system(size: 11, weight: .semibold))
                Text("拖动移动 · 双指上下滑/捏合缩放 · 双击关闭 · R 旋转 · X 鼠标穿透 · ⌘0 原始大小 · ⌥+滚动 透明度 · F3 收回全部")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.settings.pinsParticipateInCapture == false {
                Text("提示：关闭\"包含已有贴图\"时，若截图与贴图重叠，贴图会在截图瞬间消失。")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(20)
    }
}
