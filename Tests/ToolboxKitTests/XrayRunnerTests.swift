import Foundation
import Testing
@testable import ToolboxKit

private final class FakeProcess: XrayProcessProtocol {
    var isRunning = false
    var killed = false
    var onExit: (() -> Void)?
    func launch() throws { isRunning = true }
    func kill() { isRunning = false; killed = true }
    func simulateCrash() { isRunning = false; onExit?() }
}

/// 进程要能被 runner 的闭包持续追加，必须放引用盒子里
/// （返回局部 `var made` 的副本永远是空的，测试会越界）。
@MainActor
private final class ProcessBox { var procs: [FakeProcess] = [] }

@MainActor
private func makeRunner(maxAttempts: Int = 3) -> (XrayRunner, ProcessBox, URL) {
    let box = ProcessBox()
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("xrayrunner-\(UUID().uuidString)")
    let cfg = dir.appendingPathComponent("config.json")
    let r = XrayRunner(
        factory: { let p = FakeProcess(); box.procs.append(p); return p },
        configURL: cfg,
        scheduler: { work in work() },        // 立即执行，测退避不用真等
        maxAttempts: maxAttempts)
    return (r, box, cfg)
}

@Test @MainActor func startWritesConfigAndLaunches() throws {
    let (r, box, cfg) = makeRunner()
    let data = Data("{\"x\":1}".utf8)
    r.start(config: data)
    #expect(r.state == .running)
    #expect(box.procs.count == 1)
    #expect(box.procs[0].isRunning)
    #expect(try Data(contentsOf: cfg) == data)     // config 落到了 xray 会找 geoip 的那个目录
    r.stop()
    try? FileManager.default.removeItem(at: cfg.deletingLastPathComponent())
}

@Test @MainActor func stopKillsAndResets() throws {
    let (r, box, cfg) = makeRunner()
    r.start(config: Data("{}".utf8))
    r.stop()
    #expect(r.state == .stopped)
    #expect(box.procs[0].killed)
    // 主动 stop 不该触发崩溃重启
    #expect(box.procs.count == 1)
    try? FileManager.default.removeItem(at: cfg.deletingLastPathComponent())
}

@Test @MainActor func crashRelaunchesWithBackoff() throws {
    let (r, box, cfg) = makeRunner(maxAttempts: 3)
    r.start(config: Data("{}".utf8))
    box.procs[0].simulateCrash()
    #expect(box.procs.count == 2)          // 立即退避重启了一个新进程
    #expect(r.state == .running)
    #expect(box.procs[1].isRunning)
    try? FileManager.default.removeItem(at: cfg.deletingLastPathComponent())
}

@Test @MainActor func givesUpAfterMaxAttempts() throws {
    let (r, box, cfg) = makeRunner(maxAttempts: 3)
    r.start(config: Data("{}".utf8))
    // 连续崩 3 次
    box.procs[0].simulateCrash()   // attempts=1 → 重启 box.procs[1]
    box.procs[1].simulateCrash()   // attempts=2 → 重启 box.procs[2]
    box.procs[2].simulateCrash()   // attempts=3 → 放弃
    #expect(r.state == .failed("xray 连续崩溃 3 次，已停止重试"))
    #expect(box.procs.count == 3)          // 没有第四个
    try? FileManager.default.removeItem(at: cfg.deletingLastPathComponent())
}

@Test @MainActor func updateRestartsWithNewConfig() throws {
    let (r, box, cfg) = makeRunner()
    r.start(config: Data("old".utf8))
    r.update(config: Data("new".utf8))
    #expect(box.procs[0].killed)                 // 旧进程被停
    #expect(box.procs.count == 2)                // 起了新的
    #expect(try String(contentsOf: cfg, encoding: .utf8) == "new")
    #expect(r.state == .running)
    try? FileManager.default.removeItem(at: cfg.deletingLastPathComponent())
}

@Test @MainActor func lateExitFromOldProcessIsIgnored() throws {
    let (r, box, cfg) = makeRunner()
    r.start(config: Data("{}".utf8))
    r.update(config: Data("{}".utf8))       // box.procs[0] 被 kill，box.procs[1] 起来
    let before = box.procs.count
    box.procs[0].simulateCrash()                 // 旧进程"迟到"的退出回调
    #expect(box.procs.count == before)           // 不该因此再重启
    #expect(r.state == .running)
    try? FileManager.default.removeItem(at: cfg.deletingLastPathComponent())
}

@Test @MainActor func updateFromStoppedJustStarts() throws {
    let (r, box, cfg) = makeRunner()
    r.update(config: Data("{}".utf8))       // 没在跑 → 等同 start
    #expect(r.state == .running)
    #expect(box.procs.count == 1)
    try? FileManager.default.removeItem(at: cfg.deletingLastPathComponent())
}
