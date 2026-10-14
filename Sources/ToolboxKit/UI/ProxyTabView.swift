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
                Divider()
                updateSection
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
                if let lat = vm.latencyText {
                    Text(lat).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Button("测延迟") { Task { await vm.testLatency() } }
                    .controlSize(.small)
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
                ForEach(ProxyRoutingMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
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

    // MARK: 更新

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("更新").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(vm.updateBusy ? "检查中…" : "检查更新") { Task { await vm.checkForUpdates() } }
                    .disabled(vm.updateBusy).controlSize(.small)
            }
            if let info = vm.updateInfo {
                row("内核", current: info.coreCurrent, latest: info.coreLatest,
                    available: info.coreUpdateAvailable) { Task { await vm.applyCoreUpdate() } }
                row("规则库(geoip/geosite)", current: info.rulesCurrent ?? "内置", latest: info.rulesLatest,
                    available: info.rulesUpdateAvailable) { Task { await vm.applyRulesUpdate() } }
            }
            if let m = vm.updateMessage {
                Text(m).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, current: String, latest: String?, available: Bool,
                     update: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11))
            Text(current).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            if let latest, available {
                Text("→ \(latest)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.orange)
                Button("更新", action: update).disabled(vm.updateBusy).controlSize(.mini)
            }
            Spacer()
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
