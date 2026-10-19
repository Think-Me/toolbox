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
    @Published public var updateInfo: UpdateInfo?
    @Published public var updateBusy = false
    @Published public var updateProgress: Double?
    @Published public var updateMessage: String?
    /// 检查/更新走本地代理还是直连。GitHub 国内直连常失败，
    /// 但走代理要求内核已在跑（否则没有代理可走），所以默认直连、由用户切。
    @Published public var updateViaProxy = false

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
        guard let config = currentConfig() else { return }
        runner.start(config: config)
    }

    /// 按当前模式生成配置：自动切换用勾选的候选组，手动用选中的单节点。
    /// 返回 nil 表示前置条件不满足（已设置 message）。
    private func currentConfig() -> Data? {
        let candidates = library.nodes.filter(\.balancerCandidate)
        if library.runtime.autoSwitch {
            guard !candidates.isEmpty else {
                message = "自动切换需至少勾选一个候选节点"; return nil
            }
            let node = activeNode ?? candidates[0]
            return XrayConfigCompiler.compileData(node: node, runtime: library.runtime, candidates: candidates)
        }
        guard let node = activeNode else { message = "先添加并选择一个节点"; return nil }
        return XrayConfigCompiler.compileData(node: node, runtime: library.runtime)
    }

    public func stopEngine() { runner.stop() }

    private func restart() {
        guard let config = currentConfig() else { return }
        runner.update(config: config)
    }

    /// 切换某节点是否进候选组
    public func toggleCandidate(_ id: UUID) {
        guard let i = library.nodes.firstIndex(where: { $0.id == id }) else { return }
        library.nodes[i].balancerCandidate.toggle()
        persist()
        if isEngineRunning && library.runtime.autoSwitch { restart() }
    }

    public func setAutoSwitch(_ on: Bool) {
        library.runtime.autoSwitch = on
        persist()
        if isEngineRunning { restart() }
    }

    public func setProbeInterval(_ seconds: Int) {
        library.runtime.probeIntervalSeconds = max(5, seconds)
        persist()
        if isEngineRunning && library.runtime.autoSwitch { restart() }
    }

    /// 经本地 SOCKS 打一次真实请求测延迟。需要内核在跑且有可用节点。
    public func testLatency() async {
        guard isEngineRunning else { latencyText = "先启动代理"; return }
        latencyText = "测试中…"
        let r = await LatencyProbe.measureThroughProxy(port: library.runtime.httpPort)
        switch r {
        case .milliseconds(let ms): latencyText = "延迟 \(ms) ms"
        case .failed(let m): latencyText = "不通：\(m)"
        }
    }

    // MARK: 更新

    /// 按用户选择构造 fetcher；选了走代理但内核没跑，自动退回直连并说明。
    private func updateFetcher() -> (fetcher: any HTTPFetching, note: String?) {
        if updateViaProxy {
            if isEngineRunning {
                return (URLSessionFetcher(proxyPort: library.runtime.httpPort), nil)
            }
            return (URLSessionFetcher(), "代理未运行，本次改用直连")
        }
        return (URLSessionFetcher(), nil)
    }

    public func checkForUpdates() async {
        updateBusy = true
        let (fetcher, note) = updateFetcher()
        updateMessage = note ?? "检查中…"
        let info = await UpdateService.check(paths: paths, fetcher: fetcher)
        updateInfo = info
        updateBusy = false
        updateMessage = (info.coreUpdateAvailable || info.rulesUpdateAvailable) ? "有可用更新" : "已是最新"
    }

    public func applyCoreUpdate() async {
        guard let tag = updateInfo?.coreLatest, tag != updateInfo?.coreCurrent else { return }
        updateBusy = true
        updateProgress = nil          // 未知长度时保持 nil → UI 显示不确定态
        updateMessage = "下载内核…"
        let (fetcher, _) = updateFetcher()
        let r = await UpdateService.applyCoreUpdate(tag: tag, paths: paths, fetcher: fetcher) { [weak self] p in
            Task { @MainActor in self?.updateProgress = p }
        }
        switch r {
        case .success:
            updateMessage = "内核已更新到 \(tag)"
            if isEngineRunning { restart() }
            await checkForUpdates()
        case .failure(let e): updateMessage = "内核更新失败：\(e)"
        }
        updateProgress = nil
        updateBusy = false
    }

    public func applyRulesUpdate() async {
        guard let tag = updateInfo?.rulesLatest else { return }
        updateBusy = true
        updateProgress = nil
        updateMessage = "下载规则库…"
        let (fetcher, _) = updateFetcher()
        let r = await UpdateService.applyRulesUpdate(tag: tag, paths: paths, fetcher: fetcher) { [weak self] p in
            Task { @MainActor in self?.updateProgress = p }
        }
        switch r {
        case .success:
            updateMessage = "规则库已更新到 \(tag)"
            if isEngineRunning { restart() }
            await checkForUpdates()
        case .failure(let e): updateMessage = "规则库更新失败：\(e)"
        }
        updateProgress = nil
        updateBusy = false
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
