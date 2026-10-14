import Foundation

/// 被托管的进程。抽象出来是为了让"崩溃→退避重启→超限放弃"这套生命周期
/// 能用假进程同步测，而不是靠真 sleep 和真 xray。
public protocol XrayProcessProtocol: AnyObject {
    var isRunning: Bool { get }
    func launch() throws
    func kill()
    /// 进程退出时回调（无论正常还是崩溃）。由 runner 决定算不算异常退出。
    var onExit: (() -> Void)? { get set }
}

/// 真进程：包一个 Process 跑 `xray run -c config.json`。
final class ProcessXray: XrayProcessProtocol, @unchecked Sendable {
    private let executable: URL
    private let arguments: [String]
    private let workingDirectory: URL
    private var process: Process?
    var onExit: (() -> Void)?

    init(executable: URL, arguments: [String], workingDirectory: URL) {
        self.executable = executable; self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func launch() throws {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.currentDirectoryURL = workingDirectory
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            // terminationHandler 在非主线程触发，跳回主线程再动 runner 状态
            DispatchQueue.main.async { self.onExit?() }
        }
        try p.run()
        process = p
    }

    func kill() {
        guard let p = process, p.isRunning else { return }
        p.terminationHandler = nil          // 主动停的不算崩溃
        p.terminate()
        process = nil
    }
}

/// 托管单个 xray 进程：启动/停止/改配置重启/崩溃退避重启/超限放弃。
///
/// 生命周期必须收口在这里，别处不许再各自起 xray —— 否则会出现两个进程抢同一
/// 个 SOCKS 端口、或 App 退出后留孤儿继续占端口（下次启动直接 bind 失败）。
@MainActor
public final class XrayRunner {
    public enum State: Equatable {
        case stopped
        case running
        case failed(String)
    }

    public private(set) var state: State = .stopped
    public var onStateChange: ((State) -> Void)?

    private let factory: () -> any XrayProcessProtocol
    private let configURL: URL
    private let scheduler: (@escaping () -> Void) -> Void   // 退避延迟；测试里立即执行
    private let maxAttempts: Int
    private var process: (any XrayProcessProtocol)?
    private var attempts = 0
    private var stoppingIntentionally = false

    /// - Parameters:
    ///   - factory: 造一个进程（注入假进程做测试）
    ///   - configURL: 写 config.json 的位置（xray 靠它同目录找 geoip.dat）
    ///   - scheduler: 延迟执行闭包；默认用主队列 asyncAfter
    public init(factory: @escaping () -> any XrayProcessProtocol,
                configURL: URL,
                scheduler: @escaping (@escaping () -> Void) -> Void = { work in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
                },
                maxAttempts: Int = 5) {
        self.factory = factory; self.configURL = configURL
        self.scheduler = scheduler; self.maxAttempts = maxAttempts
    }

    /// 写配置并启动（幂等：已在跑则视为重启，先停后起）。
    public func start(config: Data) {
        do {
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try config.write(to: configURL, options: .atomic)
        } catch {
            transition(to: .failed("写 config 失败: \(error.localizedDescription)"))
            return
        }
        launchProcess()
    }

    /// 改配置 → 重启。
    public func update(config: Data) {
        guard state != .stopped else { start(config: config); return }
        stoppingIntentionally = true
        process?.kill()
        stoppingIntentionally = false
        attempts = 0
        start(config: config)
    }

    public func stop() {
        guard process != nil || state != .stopped else { return }
        stoppingIntentionally = true
        process?.kill()
        process = nil
        attempts = 0
        transition(to: .stopped)
    }

    private func launchProcess() {
        let p = factory()
        p.onExit = { [weak self] in MainActor.assumeIsolated { self?.handleExit(p) } }
        do {
            try p.launch()
        } catch {
            transition(to: .failed("启动 xray 失败: \(error.localizedDescription)"))
            return
        }
        process = p
        attempts = 0
        transition(to: .running)
    }

    private func handleExit(_ p: any XrayProcessProtocol) {
        // 主动 stop/update 触发的退出，不当崩溃处理
        guard !stoppingIntentionally else { return }
        guard p === process else { return }     // 旧进程的迟到回调，忽略
        process = nil
        attempts += 1
        if attempts >= maxAttempts {
            transition(to: .failed("xray 连续崩溃 \(attempts) 次，已停止重试"))
            return
        }
        transition(to: .running)                 // 仍算运行中（正在退避重启）
        scheduler { [weak self] in
            guard let self, !self.stoppingIntentionally, self.process == nil else { return }
            // 重新读回已写好的 config 再拉一次
            if let data = try? Data(contentsOf: self.configURL) {
                self.launchProcessWithData(data)
            }
        }
    }

    private func launchProcessWithData(_ data: Data) {
        let p = factory()
        p.onExit = { [weak self] in MainActor.assumeIsolated { self?.handleExit(p) } }
        do { try p.launch() } catch {
            transition(to: .failed("重启 xray 失败: \(error.localizedDescription)")); return
        }
        process = p
        transition(to: .running)
    }

    private func transition(to s: State) {
        state = s
        onStateChange?(s)
    }
}
