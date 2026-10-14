import Foundation
import SwiftUI

/// 代理模块的 UI 状态源。本身不含业务逻辑——解析/编译/进程/系统代理都已各自单测，
/// 这里只做编排。
@MainActor
public final class ProxyViewModel: ObservableObject {
    @Published public var library: ProxyLibrary
    @Published public var engineState: XrayRunner.State = .stopped
    @Published public var systemProxyOn = false
    @Published public var message: String?
    @Published public var addField = ""
    @Published public var latencyText: String?

    private let store: ProxyStore
    private let paths: AppPaths
    private let runner: XrayRunner
    public let engineAvailable: Bool

    public init(paths: AppPaths = .standard()) {
        self.paths = paths
        self.store = ProxyStore(file: paths.proxyLibrary)
        self.library = store.load()
        let boot = XrayBootstrap.ensureInstalled(paths: paths)
        self.engineAvailable = (try? boot.get()) != nil
        let cfg = paths.proxyDirectory.appendingPathComponent("config.json")
        let exe = paths.proxyDirectory.appendingPathComponent("xray")
        let dir = paths.proxyDirectory
        self.runner = XrayRunner(factory: {
            ProcessXray(executable: exe, arguments: ["run", "-c", cfg.path], workingDirectory: dir)
        }, configURL: cfg)
        runner.onStateChange = { [weak self] s in self?.engineState = s }
    }

    public var isEngineRunning: Bool {
        if case .running = engineState { return true }
        return false
    }
    public var activeNode: ProxyNode? { library.activeNode }

    // MARK: 节点增删改

    /// 粘贴一条分享链接添加。返回错误提示（nil = 成功）。
    @discardableResult
    public func addFromLink() -> String? {
        switch NodeLinkParser.parse(addField) {
        case .failure(let e):
            let msg = describe(e)
            message = msg
            return msg
        case .success(let node):
            library = ProxyStore.adding(node, to: library)
            persist()
            addField = ""
            message = "已添加「\(node.name)」"
            if isEngineRunning { startEngine() }   // 改了选中节点，重启到新节点
            return nil
        }
    }

    public func remove(_ id: UUID) {
        library = ProxyStore.removing(id, from: library)
        persist()
        if isEngineRunning { startEngine() }
    }

    public func select(_ id: UUID) {
        library = ProxyStore.settingActive(id, in: library)
        persist()
        if isEngineRunning { startEngine() }
    }

    public func setMode(_ mode: ProxyRoutingMode) {
        library.runtime.routingMode = mode
        persist()
        if isEngineRunning { restart() }
    }

    public func setPorts(socks: Int, http: Int) {
        guard socks > 0, socks < 65536, http > 0, http < 65536 else { return }
        library.runtime.socksPort = socks
        library.runtime.httpPort = http
        persist()
        if isEngineRunning { restart() }
        if systemProxyOn { _ = SystemProxy.enable(httpPort: http, socksPort: socks) }  // 端口变了重指
    }

    // MARK: 引擎

    public func toggleEngine() { isEngineRunning ? stopEngine() : startEngine() }

    public func startEngine() {
        guard engineAvailable else { message = "内核未就绪（构建时没跑 fetch-xray.sh）"; return }
        guard let node = activeNode else { message = "先添加并选择一个节点"; return }
        runner.start(config: XrayConfigCompiler.compileData(node: node, runtime: library.runtime))
    }

    public func stopEngine() { runner.stop() }

    private func restart() {
        guard let node = activeNode else { return }
        runner.update(config: XrayConfigCompiler.compileData(node: node, runtime: library.runtime))
    }

    /// 经本地 SOCKS 打一次真实请求测延迟。需要内核在跑且有可用节点。
    public func testLatency() async {
        guard isEngineRunning else { latencyText = "先启动代理"; return }
        latencyText = "测试中…"
        let r = await LatencyProbe.measureThroughSocks(port: library.runtime.socksPort)
        switch r {
        case .milliseconds(let ms): latencyText = "延迟 \(ms) ms"
        case .failed(let m): latencyText = "不通：\(m)"
        }
    }

    // MARK: 系统代理

    public func toggleSystemProxy() {
        if systemProxyOn {
            switch SystemProxy.disable() {
            case .success: systemProxyOn = false; message = "已关闭系统代理"
            case .failure(let e): message = "关闭系统代理失败：\(describe(e))"
            }
        } else {
            guard isEngineRunning else { message = "请先启动代理内核"; return }
            switch SystemProxy.enable(httpPort: library.runtime.httpPort,
                                      socksPort: library.runtime.socksPort) {
            case .success: systemProxyOn = true; message = "已设为系统代理"
            case .failure(let e): message = "设置系统代理失败：\(describe(e))"
            }
        }
    }

    /// App 退出前调用：**必须**关掉系统代理，否则用户整个系统的流量会指向
    /// 一个已经死掉的本地端口，表现为"关掉 Toolbox 后全网打不开"。
    public func shutdown() {
        runner.stop()
        if systemProxyOn { _ = SystemProxy.disable() }
    }

    private func persist() { try? store.save(library) }

    private func describe(_ e: NodeParseError) -> String {
        switch e {
        case .empty: return "链接为空"
        case .unknownScheme(let s): return "无法识别的链接：\(s)"
        case .malformed(let m): return "链接格式有误：\(m)"
        case .badBase64: return "链接解码失败"
        }
    }
    private func describe(_ e: SystemProxy.SystemProxyError) -> String {
        switch e {
        case .noActiveService: return "找不到当前网络服务"
        case .commandFailed(let m): return m
        }
    }
}
