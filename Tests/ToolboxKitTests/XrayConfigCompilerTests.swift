import Foundation
import Testing
@testable import ToolboxKit

private func json(_ node: ProxyNode, _ mode: ProxyRoutingMode,
                  socks: Int = 10808, http: Int = 10809) -> [String: Any] {
    let data = XrayConfigCompiler.compileData(
        node: node, runtime: .init(socksPort: socks, httpPort: http, routingMode: mode))
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

private func outbound(_ root: [String: Any]) -> [String: Any] {
    ((root["outbounds"] as? [[String: Any]])?.first) ?? [:]
}

@Test func inboundsAreSocksAndHttpOnLoopback() {
    let root = json(ProxyNode(name: "n", kind: .vmess, server: "1.2.3.4", port: 443, uuid: "u"), .global)
    let inb = (root["inbounds"] as? [[String: Any]]) ?? []
    #expect(inb.count == 2)
    #expect(inb[0]["protocol"] as? String == "socks")
    #expect(inb[0]["port"] as? Int == 10808)
    #expect(inb[0]["listen"] as? String == "127.0.0.1")
    #expect(inb[1]["protocol"] as? String == "http")
    #expect(inb[1]["port"] as? Int == 10809)
}

@Test func vmessOutboundShape() {
    let node = ProxyNode(name: "n", kind: .vmess, server: "1.2.3.4", port: 443,
                         uuid: "abc", security: "auto", alterID: "1",
                         transport: .ws, host: "h", path: "/p", useTLS: true, sni: "h")
    let ob = outbound(json(node, .global))
    #expect(ob["protocol"] as? String == "vmess")
    let vnext = (((ob["settings"] as? [String: Any])?["vnext"] as? [[String: Any]])?.first) ?? [:]
    #expect(vnext["address"] as? String == "1.2.3.4")
    #expect(vnext["port"] as? Int == 443)
    let user = ((vnext["users"] as? [[String: Any]])?.first) ?? [:]
    #expect(user["id"] as? String == "abc")
    #expect(user["alterId"] as? Int == 1)
    #expect(user["security"] as? String == "auto")
    let stream = (ob["streamSettings"] as? [String: Any]) ?? [:]
    #expect(stream["network"] as? String == "ws")
    #expect(stream["security"] as? String == "tls")
    #expect(((stream["wsSettings"] as? [String: Any])?["path"]) as? String == "/p")
    #expect(((stream["tlsSettings"] as? [String: Any])?["serverName"]) as? String == "h")
}

@Test func plainTcpNoTlsOmitsStreamSettings() {
    let node = ProxyNode(name: "n", kind: .vmess, server: "1.2.3.4", port: 443, uuid: "u",
                         transport: .tcp, useTLS: false)
    let ob = outbound(json(node, .global))
    #expect(ob["streamSettings"] == nil)
}

@Test func vlessRealityShape() {
    let node = ProxyNode(name: "n", kind: .vless, server: "1.2.3.4", port: 8443, uuid: "u",
                         flow: "xtls-rprx-vision", useTLS: true, sni: "www.microsoft.com",
                         fingerprint: "chrome", isReality: true, publicKey: "PUB", shortID: "SID")
    let ob = outbound(json(node, .global))
    #expect(ob["protocol"] as? String == "vless")
    let user = (((((ob["settings"] as? [String: Any])?["vnext"] as? [[String: Any]])?.first)?["users"] as? [[String: Any]])?.first) ?? [:]
    #expect(user["encryption"] as? String == "none")
    #expect(user["flow"] as? String == "xtls-rprx-vision")
    let stream = (ob["streamSettings"] as? [String: Any]) ?? [:]
    #expect(stream["security"] as? String == "reality")
    let reality = (stream["realitySettings"] as? [String: Any]) ?? [:]
    #expect(reality["publicKey"] as? String == "PUB")
    #expect(reality["shortId"] as? String == "SID")
    #expect(reality["fingerprint"] as? String == "chrome")
}

@Test func shadowsocksAndTrojanShapes() {
    let ss = outbound(json(ProxyNode(name: "n", kind: .shadowsocks, server: "1.2.3.4", port: 8388,
                                     password: "pw", security: "aes-256-gcm"), .global))
    #expect(ss["protocol"] as? String == "shadowsocks")
    let ssSet = (ss["settings"] as? [String: Any]) ?? [:]
    #expect(ssSet["method"] as? String == "aes-256-gcm")
    #expect(ssSet["password"] as? String == "pw")

    let tj = outbound(json(ProxyNode(name: "n", kind: .trojan, server: "1.2.3.4", port: 443,
                                     password: "tpw", useTLS: true, sni: "s"), .global))
    #expect(tj["protocol"] as? String == "trojan")
    let servers = (((tj["settings"] as? [String: Any])?["servers"] as? [[String: Any]])?.first) ?? [:]
    #expect(servers["password"] as? String == "tpw")
}

// MARK: 路由模式

private func rules(_ root: [String: Any]) -> [[String: Any]] {
    (((root["routing"] as? [String: Any])?["rules"]) as? [[String: Any]]) ?? []
}

@Test func globalModeHasNoMainlandBypass() {
    let r = rules(json(ProxyNode(name: "n", kind: .vmess, server: "s", port: 1, uuid: "u"), .global))
    let allIPs = r.compactMap { $0["ip"] as? [String] }.flatMap { $0 }
    #expect(allIPs.contains("geoip:private"))
    #expect(!allIPs.contains("geoip:cn"))
    #expect(!r.contains { ($0["domain"] as? [String])?.contains("geosite:cn") == true })
}

@Test func bypassMainlandUsesIpAndDomainPrefixedGeoRules() {
    // 关键：必须是 "ip":["geoip:cn"] 和 "domain":["geosite:cn"]，
    // 不是独立的 "geoip" 字段（本版本 xray 不认，spec §1.1 #34）
    let r = rules(json(ProxyNode(name: "n", kind: .vmess, server: "s", port: 1, uuid: "u"), .bypassMainland))
    #expect(r.contains { ($0["ip"] as? [String])?.contains("geoip:cn") == true && $0["outboundTag"] as? String == "direct" })
    #expect(r.contains { ($0["domain"] as? [String])?.contains("geosite:cn") == true && $0["outboundTag"] as? String == "direct" })
    // 绝不该出现独立的 "geoip" 键
    #expect(!r.contains { $0["geoip"] != nil })
}

@Test func defaultOutboundIsProxyAndDirectExists() {
    let root = json(ProxyNode(name: "n", kind: .vmess, server: "s", port: 1, uuid: "u"), .global)
    let tags = ((root["outbounds"] as? [[String: Any]]) ?? []).compactMap { $0["tag"] as? String }
    #expect(tags.first == "proxy")     // xray 用第一个 outbound 作默认
    #expect(tags.contains("direct"))
}

// MARK: 集成：真用内置 xray 验证 config 能起来

@Test func compiledConfigActuallyBootsXray() throws {
    // 从测试文件回溯到仓库根，找 Vendor/xray/xray；没下载就跳过
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let vendor = repoRoot.appendingPathComponent("Vendor/xray")
    let xray = vendor.appendingPathComponent("xray")
    guard FileManager.default.isExecutableFile(atPath: xray.path) else { return }

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("xraycfg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    // xray 在 config 同目录找 geoip.dat（#35）→ 软链过去
    for f in ["geoip.dat", "geosite.dat"] {
        try? FileManager.default.createSymbolicLink(
            at: tmp.appendingPathComponent(f), withDestinationURL: vendor.appendingPathComponent(f))
    }
    let node = ProxyNode(name: "t", kind: .vmess, server: "127.0.0.1", port: 443, uuid: "u",
                         transport: .ws, host: "h", path: "/p", useTLS: false)
    let cfg = tmp.appendingPathComponent("config.json")
    try XrayConfigCompiler.compileData(node: node,
        runtime: .init(socksPort: 20170, httpPort: 20171, routingMode: .bypassMainland))
        .write(to: cfg)

    let p = Process()
    p.executableURL = xray
    p.arguments = ["run", "-c", cfg.path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    usleep(1_500_000)
    let diedEarly = p.isRunning == false
    if p.isRunning { p.terminate(); p.waitUntilExit() }
    // 配置有错（含 geoip 规则写错）会让 xray 立即退出
    #expect(diedEarly == false, "xray 未能用生成的 config 启动")
}
