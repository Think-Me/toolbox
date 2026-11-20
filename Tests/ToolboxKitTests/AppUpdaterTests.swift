import Foundation
import Testing
@testable import ToolboxKit

private func releaseJSON(tag: String = "v0.9.9", dmg: String? = "https://github.com/Think-Me/toolbox/releases/download/v0.9.9/Toolbox.dmg") -> Data {
    var assets: [[String: Any]] = []
    if let dmg { assets.append(["name": "Toolbox.dmg", "browser_download_url": dmg]) }
    assets.append(["name": "Source code.zip", "browser_download_url": "https://x/src.zip"])
    let obj: [String: Any] = ["tag_name": tag, "html_url": "https://github.com/Think-Me/toolbox/releases/tag/\(tag)", "body": "notes here", "assets": assets]
    return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
}

/// 带 mac.json 资产的新格式 release
private func releaseJSONWithMac(tag: String = "v0.4.0",
                                macURL: String = "https://github.com/Think-Me/toolbox/releases/download/v0.4.0/mac.json") -> Data {
    let dmg = "https://github.com/Think-Me/toolbox/releases/download/\(tag)/Toolbox.dmg"
    let assets: [[String: Any]] = [
        ["name": "Toolbox.dmg", "browser_download_url": dmg],
        ["name": "mac.json", "browser_download_url": macURL],
    ]
    let obj: [String: Any] = ["tag_name": tag,
                              "html_url": "https://github.com/Think-Me/toolbox/releases/tag/\(tag)",
                              "body": "notes", "assets": assets]
    return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
}

@Test func parseReleaseFindsDmgAndVersion() {
    let info = AppUpdater.parseRelease(releaseJSON())
    #expect(info?.version == "0.9.9")
    #expect(info?.tag == "v0.9.9")
    #expect(info?.dmgURL.hasSuffix("Toolbox.dmg") == true)
    #expect(info?.notes == "notes here")
}

@Test func parseReleaseNilWhenNoDmg() {
    #expect(AppUpdater.parseRelease(releaseJSON(dmg: nil)) == nil)
    #expect(AppUpdater.parseRelease(Data("{}".utf8)) == nil)
    #expect(AppUpdater.parseRelease(Data("garbage".utf8)) == nil)
}

@Test func normalizeVersionStripsLeadingV() {
    #expect(AppUpdater.normalizeVersion("v0.1.2") == "0.1.2")
    #expect(AppUpdater.normalizeVersion("V1.0") == "1.0")
    #expect(AppUpdater.normalizeVersion("0.1.2") == "0.1.2")
}

@Test func mirrorPrefixesDownloadURL() {
    let info = AppUpdater.parseRelease(releaseJSON())!
    // 空镜像 → 原样
    #expect(AppUpdater.downloadURL(for: info, mirror: "") == info.dmgURL)
    // 带尾斜杠
    #expect(AppUpdater.downloadURL(for: info, mirror: "https://ghproxy.net/") == "https://ghproxy.net/" + info.dmgURL)
    // 不带尾斜杠 → 补一个
    #expect(AppUpdater.downloadURL(for: info, mirror: "https://ghproxy.net") == "https://ghproxy.net/" + info.dmgURL)
    // 镜像只作用于下载，不碰 api（latestAPI 里没有 github.com/.../download）
    #expect(!AppUpdater.latestAPI.contains("ghproxy"))
}

@MainActor
private final class FakeFetcher: HTTPFetching, @unchecked Sendable {
    var json = ""; var macInfo: String?; var downloads: [URL] = []
    func get(_ url: URL) async throws -> Data {
        if url.absoluteString.contains("api.github.com") { return Data(json.utf8) }
        if url.lastPathComponent == "mac.json", let macInfo { return Data(macInfo.utf8) }
        throw URLError(.badServerResponse)
    }
    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws { downloads.append(url) }
}

@Test func macInfoURLAndBuildParse() {
    #expect(AppUpdater.macInfoURL(from: releaseJSONWithMac())?.lastPathComponent == "mac.json")
    #expect(AppUpdater.macInfoURL(from: releaseJSON()) == nil)   // 老 release 没有该资产
    #expect(AppUpdater.parseMacBuild(Data(#"{"macBuild":17}"#.utf8)) == 17)
    #expect(AppUpdater.parseMacBuild(Data(#"{"macBuild":"17"}"#.utf8)) == 17)
    #expect(AppUpdater.parseMacBuild(Data("garbage".utf8)) == nil)
}

@Test @MainActor func checkSkipsUpdateWhenMacBuildUnchanged() async {
    // 统一版本涨到 0.4.0，但 Mac 内容版本没变 → 不应提示更新
    let f = FakeFetcher()
    f.json = String(decoding: releaseJSONWithMac(tag: "v0.4.0"), as: UTF8.self)
    f.macInfo = #"{"macBuild":16}"#
    let r = await AppUpdater.check(currentVersion: "0.3.0", currentBuild: 16,
                                   settings: .init(), fetcher: f)
    if case .upToDate = r {} else { Issue.record("Mac 内容版本未变应判最新") }
}

@Test @MainActor func checkOffersUpdateWhenMacBuildIncreases() async {
    let f = FakeFetcher()
    f.json = String(decoding: releaseJSONWithMac(tag: "v0.4.0"), as: UTF8.self)
    f.macInfo = #"{"macBuild":17}"#
    let r = await AppUpdater.check(currentVersion: "0.3.0", currentBuild: 16,
                                   settings: .init(), fetcher: f)
    if case .available(let info) = r { #expect(info.version == "0.4.0") }
    else { Issue.record("Mac 内容版本变大应提示更新") }
}

@Test @MainActor func checkFailsWhenMacInfoUnreadable() async {
    // 有 mac.json 资产但读不到时不能退回版本号比较，否则又会误推
    let f = FakeFetcher()
    f.json = String(decoding: releaseJSONWithMac(), as: UTF8.self)
    f.macInfo = nil
    let r = await AppUpdater.check(currentVersion: "0.3.0", currentBuild: 16,
                                   settings: .init(), fetcher: f)
    if case .failed = r {} else { Issue.record("读不到 mac.json 应判 failed") }
}

@Test @MainActor func checkDetectsNewerAndSame() async {
    let f = FakeFetcher(); f.json = String(decoding: releaseJSON(), as: UTF8.self)   // v0.9.9
    let newer = await AppUpdater.check(currentVersion: "0.1.2", settings: .init(), fetcher: f)
    if case .available(let info) = newer { #expect(info.version == "0.9.9") } else { Issue.record("应检出可用更新") }

    let same = await AppUpdater.check(currentVersion: "0.9.9", settings: .init(), fetcher: f)
    if case .upToDate = same {} else { Issue.record("同版本应判最新") }

    let ahead = await AppUpdater.check(currentVersion: "9.9.9", settings: .init(), fetcher: f)
    if case .upToDate = ahead {} else { Issue.record("本地更新时应判最新") }
}

@Test @MainActor func checkReportsFailureOnBadJSON() async {
    let f = FakeFetcher(); f.json = "not json"
    if case .failed = await AppUpdater.check(currentVersion: "0.1.2", settings: .init(), fetcher: f) {}
    else { Issue.record("坏 JSON 应判 failed") }
}

@Test func swapScriptQuotedAndOrdered() throws {
    let script = AppUpdater.swapScript(
        mountApp: URL(fileURLWithPath: "/Volumes/Toolbox/Toolbox.app"),
        currentApp: URL(fileURLWithPath: "/Applications/Toolbox.app"),
        mount: URL(fileURLWithPath: "/Volumes/Toolbox"),
        dmg: URL(fileURLWithPath: "/tmp/x/Toolbox.dmg"))
    // 先等进程退出，再 rm 旧、cp 新、清隔离、detach、open
    #expect(script.contains("sleep 2"))
    let rmPos = script.range(of: "rm -rf '/Applications/Toolbox.app'")!.lowerBound
    let cpPos = script.range(of: "cp -R '/Volumes/Toolbox/Toolbox.app'")!.lowerBound
    #expect(rmPos < cpPos)
    #expect(script.contains("xattr -dr com.apple.quarantine"))
    #expect(script.contains("hdiutil detach"))
    #expect(script.hasSuffix("open '/Applications/Toolbox.app'"))
    // 路径带空格/单引号要安全转义
    let tricky = AppUpdater.swapScript(
        mountApp: URL(fileURLWithPath: "/Volumes/My App/x.app"), currentApp: URL(fileURLWithPath: "/Applications/it's.app"),
        mount: URL(fileURLWithPath: "/Volumes/My App"), dmg: URL(fileURLWithPath: "/tmp/d.dmg"))
    #expect(tricky.contains(#"'/Applications/it'\''s.app'"#))
}
