import Foundation
import Testing
@testable import ToolboxKit

private func tempWorkspace() throws -> (dir: URL, hosts: URL) {
    let dir = URL(fileURLWithPath: "/tmp/toolbox-hosts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let hosts = dir.appendingPathComponent("hosts")
    try "127.0.0.1 localhost\n".write(to: hosts, atomically: true, encoding: .utf8)
    return (dir, hosts)
}

private func inode(_ path: String) -> UInt64? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    return UInt64(st.st_ino)
}

@Test func writeReplacesContentInPlace() throws {
    let (dir, hosts) = try tempWorkspace(); defer { try? FileManager.default.removeItem(at: dir) }
    let w = DirectHostsWriter(path: hosts.path,
                              backupDirectory: dir.appendingPathComponent("backup"),
                              originalSnapshot: dir.appendingPathComponent("original"))
    try w.write("127.0.0.1 localhost\n10.0.0.1 dev.local\n")
    #expect(try w.read().contains("dev.local"))
}

/// 本文件最重要的一条测试。
///
/// `/private/etc` 不允许非 root 创建文件，所以 `.atomic`（temp + rename）在真机上必然失败；
/// 即使目录可写，rename 出来的新文件属主/权限也会变，一次性建立的 `root:admin g+w` 立刻失效。
/// 谁把实现改成原子写，这条就会红。
@Test func writeKeepsSameInode() throws {
    let (dir, hosts) = try tempWorkspace(); defer { try? FileManager.default.removeItem(at: dir) }
    let before = try #require(inode(hosts.path))
    let w = DirectHostsWriter(path: hosts.path,
                              backupDirectory: dir.appendingPathComponent("backup"),
                              originalSnapshot: dir.appendingPathComponent("original"))
    try w.write("127.0.0.1 localhost\n8.8.8.8 dns.local\n")
    #expect(try #require(inode(hosts.path)) == before, "inode 变了 = 实现被改成了 rename，/etc 下必然失败")
}

@Test func backupWrittenBeforeEachWrite() throws {
    let (dir, hosts) = try tempWorkspace(); defer { try? FileManager.default.removeItem(at: dir) }
    let backup = dir.appendingPathComponent("backup")
    let w = DirectHostsWriter(path: hosts.path, backupDirectory: backup,
                              originalSnapshot: dir.appendingPathComponent("original"))
    try w.write("v2\n")
    try w.write("v3\n")
    let files = try FileManager.default.contentsOfDirectory(atPath: backup.path)
    #expect(files.count == 2)
    // 备份里应该能看到被覆盖掉的旧内容，否则"还原"就是空话
    let contents = try files.map { try String(contentsOfFile: backup.appendingPathComponent($0).path,
                                              encoding: .utf8) }
    #expect(contents.contains("127.0.0.1 localhost\n"))
    #expect(contents.contains("v2\n"))
}

@Test func backupRotationKeepsOnlyNewestFifty() throws {
    let (dir, hosts) = try tempWorkspace(); defer { try? FileManager.default.removeItem(at: dir) }
    let backup = dir.appendingPathComponent("backup")
    let w = DirectHostsWriter(path: hosts.path, backupDirectory: backup,
                              originalSnapshot: dir.appendingPathComponent("original"),
                              maxBackups: 5)
    for i in 0..<20 { try w.write("v\(i)\n") }
    #expect(try FileManager.default.contentsOfDirectory(atPath: backup.path).count == 5)
}

@Test func originalSnapshotWrittenOnceAndNeverOverwritten() throws {
    let (dir, hosts) = try tempWorkspace(); defer { try? FileManager.default.removeItem(at: dir) }
    let original = dir.appendingPathComponent("original")
    let w = DirectHostsWriter(path: hosts.path, backupDirectory: dir.appendingPathComponent("b"),
                              originalSnapshot: original)
    try w.write("changed\n")
    let first = try String(contentsOf: original, encoding: .utf8)
    #expect(first == "127.0.0.1 localhost\n")
    try w.write("changed again\n")
    #expect(try String(contentsOf: original, encoding: .utf8) == first)  // 第二次不许覆盖
}

@Test func unwritableFileReportsNotProvisioned() throws {
    let (dir, hosts) = try tempWorkspace(); defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: hosts.path)
    let w = DirectHostsWriter(path: hosts.path, backupDirectory: dir.appendingPathComponent("b"),
                              originalSnapshot: dir.appendingPathComponent("original"))
    #expect(throws: HostsWriterError.self) { try w.write("nope\n") }
    // 权限问题必须归到 notProvisioned，而不是笼统的"写入失败"
    do {
        try w.write("nope\n")
        Issue.record("应当抛出")
    } catch let e as HostsWriterError {
        guard case .notProvisioned = e else { Issue.record("错误类型应为 notProvisioned，实际 \(e)"); return }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: hosts.path)
}

@Test func restoreFromOriginalWritesItBack() throws {
    let (dir, hosts) = try tempWorkspace(); defer { try? FileManager.default.removeItem(at: dir) }
    let w = DirectHostsWriter(path: hosts.path, backupDirectory: dir.appendingPathComponent("b"),
                              originalSnapshot: dir.appendingPathComponent("original"))
    try w.write("messed up\n")
    try w.restoreOriginal()
    #expect(try w.read() == "127.0.0.1 localhost\n")
}

@Test func readOfMissingFileThrowsNotCrash() {
    let w = DirectHostsWriter(path: "/tmp/toolbox-definitely-missing-\(UUID().uuidString)",
                              backupDirectory: URL(fileURLWithPath: "/tmp"),
                              originalSnapshot: URL(fileURLWithPath: "/tmp/x"))
    #expect(throws: (any Error).self) { _ = try w.read() }
}

// MARK: DNS

@Test func dnsFlushFailureDoesNotClaimSuccess() {
    // 本机 sudoers 已装好，这里只验证"退出码非 0 时不会假装成功"这条逻辑分支
    let failing = DnsFlusher(runner: FakeRunner(status: 1, stderr: "sudo: a password is required"))
    let r = failing.flush()
    guard case .needsProvisioned(let msg) = r else { Issue.record("应报 needsProvisioned，实际 \(r)"); return }
    #expect(msg.contains("密码") || msg.contains("授权"))
}

@Test func dnsFlushSuccessReportsOK() {
    let ok = DnsFlusher(runner: FakeRunner(status: 0, stderr: ""))
    if case .ok = ok.flush() { } else { Issue.record("应成功") }
}

@Test func dnsFlushUsesKillNotSudoForInteractivePassword() {
    // -k 是硬要求：不带它，用户 5 分钟内的 sudo ticket 缓存会让探测假阳性
    let runner = FakeRunner(status: 0, stderr: "")
    _ = DnsFlusher(runner: runner).flush()
    #expect(runner.recordedArguments.contains { $0.contains("-k") })
    #expect(runner.recordedArguments.contains { $0.contains("-flushcache") })
    #expect(runner.recordedArguments.contains { $0.contains("mDNSResponder") })
}

final class FakeRunner: DnsCommandRunning, @unchecked Sendable {
    let status: Int32
    let stderr: String
    var recordedArguments: [[String]] = []
    init(status: Int32, stderr: String) { self.status = status; self.stderr = stderr }
    func run(executable: String, arguments: [String]) -> (status: Int32, stderr: String) {
        recordedArguments.append(arguments)
        return (status, stderr)
    }
}
