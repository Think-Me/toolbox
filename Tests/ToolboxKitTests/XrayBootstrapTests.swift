import Foundation
import Testing
@testable import ToolboxKit

private func makeBundle(_ dir: URL, version: String?, files: [String] = XrayBootstrap.assetFiles) {
    let fm = FileManager.default
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for f in files {
        let url = dir.appendingPathComponent(f)
        try? Data("dummy-\(f)".utf8).write(to: url)
    }
    if let version {
        try? Data(version.utf8).write(to: dir.appendingPathComponent("version.txt"))
    }
}

@Test func shouldCopyTruthTable() {
    // 没有内置资源 → 永远不拷
    #expect(XrayBootstrap.shouldCopy(bundledVersion: nil, onDiskVersion: nil, filesPresent: false) == false)
    // 首次：文件不在 → 拷
    #expect(XrayBootstrap.shouldCopy(bundledVersion: "v1", onDiskVersion: nil, filesPresent: false) == true)
    // 已装且版本一致 → 不拷
    #expect(XrayBootstrap.shouldCopy(bundledVersion: "v1", onDiskVersion: "v1", filesPresent: true) == false)
    // App 升级换了内核 → 重拷
    #expect(XrayBootstrap.shouldCopy(bundledVersion: "v2", onDiskVersion: "v1", filesPresent: true) == true)
    // 版本一致但文件被用户删了 → 补拷
    #expect(XrayBootstrap.shouldCopy(bundledVersion: "v1", onDiskVersion: "v1", filesPresent: false) == true)
}

@Test func ensureCopiesAllThreeAndStamps() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("proxy-boot-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("bundle")
    let work = root.appendingPathComponent("Proxy")
    makeBundle(bundle, version: "v9")

    let result = XrayBootstrap.ensure(bundledDir: bundle, workDir: work)
    let xrayURL = try #require(try? result.get())
    #expect(xrayURL.lastPathComponent == "xray")
    let fm = FileManager.default
    for f in XrayBootstrap.assetFiles {
        #expect(fm.fileExists(atPath: work.appendingPathComponent(f).path))
    }
    // 可执行位补上了
    #expect(fm.isExecutableFile(atPath: work.appendingPathComponent("xray").path))
    // 写了版本戳
    let stamp = try String(contentsOf: work.appendingPathComponent(".xray-version"), encoding: .utf8)
    #expect(stamp == "v9")
}

@Test func ensureIsIdempotentThenRecopiesOnVersionBump() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("proxy-boot2-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("bundle")
    let work = root.appendingPathComponent("Proxy")
    makeBundle(bundle, version: "v9")
    _ = XrayBootstrap.ensure(bundledDir: bundle, workDir: work)

    // 篡改工作目录内容，再 ensure 一次：版本没变且文件在 → 不该重拷（内容仍是篡改值）
    let marker = work.appendingPathComponent("geoip.dat")
    try Data("tampered".utf8).write(to: marker)
    _ = XrayBootstrap.ensure(bundledDir: bundle, workDir: work)
    #expect(String(decoding: FileManager.default.contents(atPath: marker.path)!, as: UTF8.self) == "tampered")

    // 内置版本升了 → 应重拷，覆盖掉篡改内容
    makeBundle(bundle, version: "v10")
    _ = XrayBootstrap.ensure(bundledDir: bundle, workDir: work)
    #expect(String(decoding: FileManager.default.contents(atPath: marker.path)!, as: UTF8.self) != "tampered")
}

@Test func ensureFailsWithoutBundledAssets() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("proxy-boot3-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("bundle")   // 空的，没 version.txt
    let work = root.appendingPathComponent("Proxy")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let r = XrayBootstrap.ensure(bundledDir: bundle, workDir: work)
    #expect(r.failure == .some(XrayBootstrap.BootstrapError.noBundledAssets))
}

extension Result {
    var failure: Failure? { if case .failure(let e) = self { return e }; return nil }
}
