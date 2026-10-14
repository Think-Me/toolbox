import Foundation
import Testing
@testable import ToolboxKit

// MARK: 版本比较

@Test func versionComparison() {
    #expect(ProxyVersion.isNewer("v26.4.1", than: "v26.3.27"))
    #expect(!ProxyVersion.isNewer("v26.3.27", than: "v26.4.1"))
    #expect(!ProxyVersion.isNewer("v26.3.27", than: "v26.3.27"))
    #expect(ProxyVersion.isNewer("v26.3.27", than: nil))          // 没记录 → 视为可更新
    #expect(ProxyVersion.isNewer("202510010040", than: "202401010000"))  // 日期式规则版本
    #expect(!ProxyVersion.isNewer(nil, than: "v26.3.27"))
    #expect(!ProxyVersion.isNewer("", than: "v26.3.27"))
    // 位数不同也要对：26.4 vs 26.3.9 → 26.4 更新
    #expect(ProxyVersion.isNewer("26.4", than: "26.3.9"))
}

@Test func versionComponents() {
    #expect(ProxyVersion.components("v26.3.27") == [26, 3, 27])
    #expect(ProxyVersion.components("202510010040") == [202510010040])
}

// MARK: tag 解析

@Test func parsesTagFromReleaseJSON() throws {
    let json = Data("{\"tag_name\":\"v26.6.6\",\"name\":\"Xray\"}".utf8)
    #expect(UpdateService.tag(fromReleaseJSON: json) == "v26.6.6")
    #expect(UpdateService.tag(fromReleaseJSON: Data("not json".utf8)) == nil)
    #expect(UpdateService.tag(fromReleaseJSON: Data("{}".utf8)) == nil)
}

@Test func endpointURLsAreWellFormed() {
    #expect(UpdateEndpoints.xrayZip("v26.3.27").absoluteString
            == "https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-macos-arm64-v8a.zip")
    #expect(UpdateEndpoints.rulesFile("2025", "geoip.dat").absoluteString
            == "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/2025/geoip.dat")
}

// MARK: check（假 fetcher，不碰网络）

@MainActor
private final class FakeFetcher: HTTPFetching, @unchecked Sendable {
    var responses: [String: String] = [:]   // url 片段 → 返回的 JSON
    var downloads: [(URL, URL)] = []
    func get(_ url: URL) async throws -> Data {
        for (k, v) in responses where url.absoluteString.contains(k) {
            return Data(v.utf8)
        }
        throw URLError(.badServerResponse)
    }
    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws { downloads.append((url, file)) }
}

@Test @MainActor func checkReportsUpdateAvailability() async {
    let f = FakeFetcher()
    f.responses = [
        "XTLS/Xray-core": "{\"tag_name\":\"v99.0.0\"}",
        "Loyalsoldier": "{\"tag_name\":\"209901010000\"}",
    ]
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("upd-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = AppPaths(root: dir)
    try? FileManager.default.createDirectory(at: paths.proxyDirectory, withIntermediateDirectories: true)
    try? "v26.3.27".write(to: paths.proxyDirectory.appendingPathComponent(XrayBootstrap.coreStampName), atomically: true, encoding: .utf8)

    let info = await UpdateService.check(paths: paths, fetcher: f)
    #expect(info.coreCurrent == "v26.3.27")
    #expect(info.coreLatest == "v99.0.0")
    #expect(info.coreUpdateAvailable)
    #expect(info.rulesLatest == "209901010000")
    #expect(info.rulesUpdateAvailable)     // 无已记录规则版本 → 可更新
}

@Test @MainActor func checkWithNoNewerReportsUpToDate() async {
    let f = FakeFetcher()
    f.responses = ["XTLS/Xray-core": "{\"tag_name\":\"v1.0.0\"}", "Loyalsoldier": "{\"tag_name\":\"1\"}"]
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("upd2-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir.appendingPathComponent("Proxy"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = AppPaths(root: dir)
    try? "v2.0.0".write(to: paths.proxyDirectory.appendingPathComponent(XrayBootstrap.coreStampName), atomically: true, encoding: .utf8)
    try? "9".write(to: paths.proxyDirectory.appendingPathComponent("rules-version"), atomically: true, encoding: .utf8)
    let info = await UpdateService.check(paths: paths, fetcher: f)
    #expect(!info.coreUpdateAvailable)     // v1 < v2
    #expect(!info.rulesUpdateAvailable)    // 1 < 9
}
