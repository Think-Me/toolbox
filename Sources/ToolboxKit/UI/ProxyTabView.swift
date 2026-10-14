import SwiftUI

/// 设置窗「代理」页：节点管理 + 路由模式 + 端口 + 引擎开关 + 系统代理开关。
struct ProxyTabView: View {
    @ObservedObject var vm: ProxyViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statusSection
                Divider()
                nodesSection
                addSection
                Divider()
                settingsSection
                controlsSection
            }
            .padding(16)
        }
        .frame(width: 560, height: 420)
    }

    // MARK: 状态

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(engineColor).frame(width: 10, height: 10)
                Text(engineLabel).font(.system(size: 13, weight: .medium))
                Spacer()
                if vm.systemProxyOn {
                    Text("系统代理：开").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let msg = vm.message {
                Text(msg).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var engineColor: Color {
        switch vm.engineState {
        case .running: return .green
        case .stopped: return .gray
        case .failed: return .red
        }
    }
    private var engineLabel: String {
        switch vm.engineState {
        case .stopped: return "未运行"
        case .running: return "运行中 · SOCKS \(vm.library.runtime.socksPort) / HTTP \(vm.library.runtime.httpPort)"
        case .failed(let m): return "失败：\(m)"
        }
    }

    // MARK: 节点

    private var nodesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("节点").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            if vm.library.nodes.isEmpty {
                Text("还没有节点。粘贴一条 vmess/vless/trojan/ss 分享链接添加。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(vm.library.nodes) { node in
                HStack {
                    Image(systemName: node.id == vm.library.activeNodeID ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(node.id == vm.library.activeNodeID ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name).font(.system(size: 12))
                        Text(node.summary).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { vm.remove(node.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
                .contentShape(Rectangle())
                .onTapGesture { vm.select(node.id) }
            }
        }
    }

    private var addSection: some View {
        HStack {
            TextField("粘贴分享链接（vmess:// / vless:// / …）", text: $vm.addField)
                .textFieldStyle(.roundedBorder)
                .onSubmit { vm.addFromLink() }
            Button("添加") { vm.addFromLink() }
                .disabled(vm.addField.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: 路由与端口

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("路由模式", selection: Binding(
                get: { vm.library.runtime.routingMode },
                set: { vm.setMode($0) })) {
                Text("绕过大陆（大陆直连，其余代理）").tag(ProxyRoutingMode.bypassMainland)
                Text("全局（全部走代理）").tag(ProxyRoutingMode.global)
            }
            .pickerStyle(.radioGroup)
            HStack(spacing: 16) {
                stepper("SOCKS", value: vm.library.runtime.socksPort) { vm.setPorts(socks: $0, http: vm.library.runtime.httpPort) }
                stepper("HTTP", value: vm.library.runtime.httpPort) { vm.setPorts(socks: vm.library.runtime.socksPort, http: $0) }
            }
        }
    }

    private func stepper(_ label: String, value: Int, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11))
            Stepper("\(value)", value: Binding(get: { value }, set: set), in: 1...65535)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    // MARK: 开关

    private var controlsSection: some View {
        HStack(spacing: 12) {
            Button(vm.isEngineRunning ? "停止代理" : "启动代理") { vm.toggleEngine() }
                .buttonStyle(.borderedProminent)
            Toggle("设为系统代理", isOn: Binding(
                get: { vm.systemProxyOn },
                set: { _ in vm.toggleSystemProxy() }))
            Spacer()
        }
    }
}
