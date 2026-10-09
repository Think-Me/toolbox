import Foundation
import Testing
@testable import ToolboxKit

// MARK: HostsStore

private func tempFile() -> URL {
    URL(fileURLWithPath: "/tmp/toolbox-rules-\(UUID().uuidString).json")
}

@Test func missingRulesFileYieldsStarterLibrary() throws {
    let s = HostsStore(file: tempFile())
    let lib = try s.load()
    #expect(lib.managementOn == true)
    #expect(lib.groups.count == 1)
    #expect(lib.allRules.count == 1)
}

@Test func roundTripKeepsGroupsAndRuleKinds() throws {
    let f = tempFile(); defer { try? FileManager.default.removeItem(at: f) }
    var lib = HostsLibrary(groups: [
        RuleGroup(name: "公司", rules: [
            Rule(name: "内网", enabled: true, kind: .inline(content: "10.0.0.1 intranet.local")),
            Rule(name: "远程", kind: .remote(url: "https://x/y.txt", cachedContent: "1.2.3.4 r.com")),
            Rule(name: "本地文件", kind: .localFile(path: "/tmp/a.hosts")),
        ]),
        RuleGroup(name: "个人", collapsed: true, rules: [
            Rule(name: "测试", enabled: true, kind: .inline(content: "9.9.9.9 t.com")),
        ]),
    ])
    lib.managementOn = false
    try HostsStore(file: f).save(lib)
    let back = try HostsStore(file: f).load()
    #expect(back == lib)
    #expect(back.groups.count == 2)
    #expect(back.allRules.count == 4)
    #expect(back.enabledRules.map(\.name) == ["内网", "测试"])
}

@Test func corruptRulesFileIsQuarantinedNotCrash() throws {
    let f = tempFile(); defer { try? FileManager.default.removeItem(at: f) }
    try Data("{{{ not json".utf8).write(to: f)
    let loaded = try HostsStore(file: f).load()
    #expect(loaded == .starter)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.deletingLastPathComponent().path)
        .filter { $0.hasPrefix(f.lastPathComponent + ".corrupt-") }
    #expect(leftovers.count == 1)
}

@Test func toggleFlipsExactlyOneRule() throws {
    let f = tempFile(); defer { try? FileManager.default.removeItem(at: f) }
    let store = HostsStore(file: f)
    var lib = HostsLibrary(groups: [RuleGroup(name: "g", rules: [
        Rule(id: UUID(), name: "a", enabled: false, kind: .inline(content: "1.1.1.1 a")),
        Rule(id: UUID(), name: "b", enabled: false, kind: .inline(content: "2.2.2.2 b")),
    ])])
    try store.save(lib)
    let idA = lib.groups[0].rules[0].id
    try store.toggle(ruleID: idA, in: &lib)
    #expect(lib.groups[0].rules[0].enabled == true)
    #expect(lib.groups[0].rules[1].enabled == false)
}

// MARK: HostsApplying

/// 测试替身。用带锁的 class 而不是 actor：
/// `HostsWriting` 的方法是**非隔离**的，actor 满足它会造成隔离跨界（Swift 6 直接报错）。
private final class FakeWriter: HostsWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _content: String
    private var _writes: [String] = []
    var failWith: Error?
    init(_ c: String) { _content = c }
    func read() throws -> String { lock.lock(); defer { lock.unlock() }; return _content }
    func write(_ content: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let failWith { throw failWith }
        _writes.append(content)
        _content = content
    }
    func restoreOriginal() throws { lock.lock(); defer { lock.unlock() }; _writes.append("RESTORE") }
    var writes: [String] { lock.lock(); defer { lock.unlock() }; return _writes }
    var writeCount: Int { writes.count }
    var lastWrite: String? { writes.last }
}

private struct FakeDns: DnsFlushing {
    let outcome: DnsFlushOutcome
    func flush() -> DnsFlushOutcome { outcome }
}

private func makeApplying(hosts: String, dns: DnsFlushOutcome = .ok) async
    -> (HostsApplying, FakeWriter) {
    let w = FakeWriter(hosts)
    let applying = HostsApplying(writer: w, dns: FakeDns(outcome: dns))
    return (applying, w)
}

@Test func applyWritesCompiledBlock() async throws {
    let (applying, w) = await makeApplying(hosts: "127.0.0.1 localhost\n")
    let lib = HostsLibrary(groups: [RuleGroup(name: "g", rules: [
        Rule(name: "a", enabled: true, kind: .inline(content: "10.0.0.1 dev.local")),
    ])])
    let outcome = try await applying.apply(library: lib)
    guard case .success(let r) = outcome else { Issue.record("应成功"); return }
    #expect(r.conflicts.isEmpty)
    let written = try #require(w.lastWrite)
    #expect(written.contains("dev.local"))
    #expect(written.contains("localhost"))
}

@Test func applyWithNothingEnabledWritesCleanHosts() async throws {
    // 起点必须带一个已存在的块，否则"清空"后内容与原文件相同、
    // 会被"内容没变就不写"的优化合法跳过（那个优化本身是对的：少一次无谓备份）
    let seeded = try #require(try? RuleCompiler.compile(
        enabled: [NamedRule(name: "old", content: "10.0.0.9 old.local")],
        currentHosts: "127.0.0.1 localhost\n").get()).content
    let (applying, w) = await makeApplying(hosts: seeded)
    let lib = HostsLibrary(groups: [RuleGroup(name: "g", rules: [
        Rule(name: "a", enabled: false, kind: .inline(content: "10.0.0.1 dev.local")),
    ])])
    _ = try await applying.apply(library: lib)
    let written = try #require(w.lastWrite)
    #expect(written.contains("dev.local") == false)
    #expect(written.contains("old.local") == false)
    #expect(written.contains("localhost"))
}

@Test func unchangedContentSkipsWriteEntirely() async throws {
    // 内容没变就不碰文件：不产生新备份、不刷 DNS
    let (applying, w) = await makeApplying(hosts: "127.0.0.1 localhost\n")
    let lib = HostsLibrary(groups: [RuleGroup(name: "g", rules: [
        Rule(name: "a", enabled: false, kind: .inline(content: "10.0.0.1 dev.local")),
    ])])
    let outcome = try await applying.apply(library: lib)
    guard case .success(let r) = outcome else { Issue.record("应成功"); return }
    #expect(r.writtenBytes == 0)
    #expect(w.writeCount == 0)
}

@Test func managementOffStripsExistingBlock() async throws {
    // 起点带一个已存在的块，否则"关掉"后内容与原文件相同，
    // 会被"内容没变就不写"的优化合法跳过
    let seeded = try #require(try? RuleCompiler.compile(
        enabled: [NamedRule(name: "a", content: "10.0.0.1 dev.local")],
        currentHosts: "127.0.0.1 localhost\n").get()).content
    let (applying, w) = await makeApplying(hosts: seeded)
    var lib = HostsLibrary(groups: [RuleGroup(name: "g", rules: [
        Rule(name: "a", enabled: true, kind: .inline(content: "10.0.0.1 dev.local")),
    ])])
    lib.managementOn = false
    _ = try await applying.apply(library: lib)
    let written = try #require(w.lastWrite)
    #expect(written.contains("dev.local") == false)
    #expect(written.contains(RuleCompiler.beginSentinel) == false)
}

@Test func brokenSentinelRefusesAndDoesNotWrite() async throws {
    let broken = "127.0.0.1 localhost\n" + RuleCompiler.beginSentinel + "\n1.1.1.1 orphan.com\n"
    let (applying, w) = await makeApplying(hosts: broken)
    let lib = HostsLibrary(groups: [RuleGroup(name: "g", rules: [
        Rule(name: "a", enabled: true, kind: .inline(content: "2.2.2.2 x.com")),
    ])])
    let outcome = try await applying.apply(library: lib)
    guard case .refused = outcome else { Issue.record("必须拒绝"); return }
    #expect(w.writeCount == 0)     // 拒绝必须发生在任何写入之前
}

@Test func dnsFailureStillReportsWriteSucceededWithReason() async throws {
    let (applying, w) = await makeApplying(
        hosts: "127.0.0.1 localhost\n",
        dns: .needsProvisioned("需要授权"))
    let lib = HostsLibrary(groups: [RuleGroup(name: "g", rules: [
        Rule(name: "a", enabled: true, kind: .inline(content: "10.0.0.1 dev.local")),
    ])])
    let outcome = try await applying.apply(library: lib)
    guard case .success(let r) = outcome else { Issue.record("写入本身是成功的"); return }
    #expect(w.writeCount == 1)
    guard case .needsProvisioned = r.dns else { Issue.record("要带上 DNS 失败原因"); return }
}

@Test func writerFailureSurfacesAsFailed() async throws {
    let w = FakeWriter("127.0.0.1 localhost\n")
    w.failWith = HostsWriterError.notProvisioned(path: "/etc/hosts", reason: "x")
    let applying = HostsApplying(writer: w, dns: FakeDns(outcome: .ok))
    let lib = HostsLibrary(groups: [RuleGroup(name: "g", rules: [
        Rule(name: "a", enabled: true, kind: .inline(content: "10.0.0.1 dev.local")),
    ])])
    let outcome = try await applying.apply(library: lib)
    guard case .failed = outcome else { Issue.record("应报 failed"); return }
}

@Test func concurrentAppliesAreSerializedAndDoNotClobber() async throws {
    // 连点两条规则不能并发写同一个系统文件：必须串行读-改-写，
    // 否则两次都基于同一份旧内容，后写的把先写的整块覆盖掉。
    let (applying, w) = await makeApplying(hosts: "127.0.0.1 localhost\n")
    let libA = HostsLibrary(groups: [RuleGroup(name: "g", rules: [
        Rule(name: "a", enabled: true, kind: .inline(content: "10.0.0.1 a.local")),
    ])])
    let libB = HostsLibrary(groups: [RuleGroup(name: "g", rules: [
        Rule(name: "b", enabled: true, kind: .inline(content: "10.0.0.2 b.local")),
    ])])
    async let r1: Void = { _ = try? await applying.apply(library: libA) }()
    async let r2: Void = { _ = try? await applying.apply(library: libB) }()
    _ = await [r1, r2]
    #expect(w.writes.count == 2)
    let second = w.writes[1]
    // 只有一个块（没堆积），且内容是后一次规则 —— 说明第二次读到的是第一次写完的结果
    #expect(second.components(separatedBy: RuleCompiler.beginSentinel).count == 2)
    #expect(second.contains("b.local"))
    #expect(second.contains("a.local") == false)
}
