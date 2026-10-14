import Foundation
import Testing
@testable import ToolboxKit

private func makeBundle(_ dir: URL, version: String?) {
    let fm = FileManager.default
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for f in XrayBootstrap.coreFiles + XrayBootstrap.ruleFiles {
        try? Data("dummy-\(f)".utf8).write(to: dir.appendingPathComponent(f))
    }
    if let version {
        try? Data(version.utf8).write(to: dir.appendingPathComponent("version.txt"))
    }
}

@Test func shouldCopyCoreSemverRules() {
    // 缺失 → 拷
    #expect(XrayBootstrap.shouldCopyCore(bundledVersion: "v26.3.27", onDiskVersion: nil, present: false))
    // 内置比已装新（App 升级）→ 拷
    #expect(XrayBootstrap.shouldCopyCore(bundledVersion: "v26.4.1", onDiskVersion: "v26.3.27", present: true))
    // 已装比内置新（运行时更新过）→ 不冲掉
    #expect(!XrayBootstrap.shouldCopyCore(bundledVersion: "v26.3.27", onDiskVersion: "v26.6.6", present: true))
    // 相同 → 不拷
    #expect(!XrayBootstrap.shouldCopyCore(bundledVersion: "v26.3.27", onDiskVersion: "v26.3.27", present: true))
    // 没内置资源 → 不拷
    #expect(!XrayBootstrap.shouldCopyCore(bundledVersion: nil, onDiskVersion: nil, present: false))
}

@Test func shouldSeedRulesOnlyWhenMissing() {
    #expect(XrayBootstrap.shouldSeedRules(present: false))
    #expect(!XrayBootstrap.shouldSeedRules(present: true))   // 运行时更新过的 dat 不被 App 重启冲掉
}

@Test func ensureCopiesCoreAndDatAndStamps() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("boot-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("bundle"), work = root.appendingPathComponent("Proxy")
    makeBundle(bundle, version: "v26.3.27")
    let xrayURL = try XrayBootstrap.ensure(bundledDir: bundle, workDir: work).get()
    #expect(xrayURL.lastPathComponent == "xray")
    let fm = FileManager.default
    for f in XrayBootstrap.coreFiles + XrayBootstrap.ruleFiles {
        #expect(fm.fileExists(atPath: work.appendingPathComponent(f).path))
    }
    #expect(fm.isExecutableFile(atPath: work.appendingPathComponent("xray").path))
    let stamp = try String(contentsOf: work.appendingPathComponent(XrayBootstrap.coreStampName), encoding: .utf8)
    #expect(stamp == "v26.3.27")
}

@Test func ensurePreservesNewerRuntimeCoreAndUpdatedDat() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("boot2-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("bundle"), work = root.appendingPathComponent("Proxy")
    makeBundle(bundle, version: "v26.3.27")
    _ = XrayBootstrap.ensure(bundledDir: bundle, workDir: work)
    // 模拟运行时更新：把已装内核版本戳改新、把 dat 内容改掉
    try "v99.0.0".write(to: work.appendingPathComponent(XrayBootstrap.coreStampName), atomically: true, encoding: .utf8)
    try Data("updated-rules".utf8).write(to: work.appendingPathComponent("geoip.dat"))
    // 再 ensure 一次（App 重启）
    _ = XrayBootstrap.ensure(bundledDir: bundle, workDir: work)
    // 内置 v26 不比已装 v99 新 → 内核戳保持 v99
    let stamp = try String(contentsOf: work.appendingPathComponent(XrayBootstrap.coreStampName), encoding: .utf8)
    #expect(stamp == "v99.0.0")
    // dat 已存在 → 不重播种 → 运行时更新的内容保留
    let dat = try String(contentsOf: work.appendingPathComponent("geoip.dat"), encoding: .utf8)
    #expect(dat == "updated-rules")
}

@Test func ensureFailsWithoutBundledAssets() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("boot3-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("bundle")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let r = XrayBootstrap.ensure(bundledDir: bundle, workDir: root.appendingPathComponent("Proxy"))
    #expect(r == .failure(.noBundledAssets))
}
