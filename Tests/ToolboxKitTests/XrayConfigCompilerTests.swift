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

@Test func xhttpTransportEmitsXhttpSettings() {
    let node = ProxyNode(name: "n", kind: .vless, server: "1.2.3.4", port: 8080, uuid: "u",
                         transport: .xhttp, path: "/", useTLS: true, sni: "s",
                         isReality: true, publicKey: "PUB", shortID: "71")
    let ob = outbound(json(node, .global))
    let stream = (ob["streamSettings"] as? [String: Any]) ?? [:]
    #expect(stream["network"] as? String == "xhttp")
    #expect(stream["security"] as? String == "reality")
    let x = (stream["xhttpSettings"] as? [String: Any]) ?? [:]
    #expect(x["path"] as? String == "/")
    #expect(x["mode"] as? String == "auto")
}

@Test func gfwModeDefaultsToDirectAndProxiesOnlyGfw() {
    let root = json(ProxyNode(name: "n", kind: .vmess, server: "s", port: 1, uuid: "u"), .gfwList)
    let tags = ((root["outbounds"] as? [[String: Any]]) ?? []).compactMap { $0["tag"] as? String }
    #expect(tags.first == "direct")     // GFW 模式默认直连
    let r = rules(root)
    #expect(r.contains { ($0["domain"] as? [String])?.contains("geosite:gfw") == true && $0["outboundTag"] as? String == "proxy" })
}

@Test func globalAndBypassStillDefaultToProxy() {
    for mode in [ProxyRoutingMode.global, .bypassMainland] {
        let root = json(ProxyNode(name: "n", kind: .vmess, server: "s", port: 1, uuid: "u"), mode)
        let tags = ((root["outbounds"] as? [[String: Any]]) ?? []).compactMap { $0["tag"] as? String }
        #expect(tags.first == "proxy")
    }
}

@Test func gfwConfigBootsXray() throws {
    // geosite:gfw 码必须存在于内置 dat，否则启动即失败
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let vendor = repoRoot.appendingPathComponent("Vendor/xray")
    let xray = vendor.appendingPathComponent("xray")
    guard FileManager.default.isExecutableFile(atPath: xray.path) else { return }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gfw-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    for f in ["geoip.dat", "geosite.dat"] {
        try? FileManager.default.createSymbolicLink(at: tmp.appendingPathComponent(f), withDestinationURL: vendor.appendingPathComponent(f))
    }
    let node = ProxyNode(name: "t", kind: .vmess, server: "127.0.0.1", port: 443, uuid: "u")
    let cfg = tmp.appendingPathComponent("config.json")
    try XrayConfigCompiler.compileData(node: node,
        runtime: .init(socksPort: 20811, httpPort: 20812, routingMode: .gfwList)).write(to: cfg)
    let p = Process(); p.executableURL = xray; p.arguments = ["run", "-c", cfg.path]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try p.run(); usleep(1_500_000)
    let died = !p.isRunning
    if p.isRunning { p.terminate(); p.waitUntilExit() }
    #expect(died == false, "geosite:gfw 配置应能启动")
}

// MARK: 自动切换（balancer + observatory）

private func autoRoot(candidates: [ProxyNode], interval: Int = 30,
                      mode: ProxyRoutingMode = .global) -> [String: Any] {
    let data = XrayConfigCompiler.compileData(
        node: candidates.first!, runtime: .init(autoSwitch: true, probeIntervalSeconds: interval),
        candidates: candidates)
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}
private func vless(_ name: String, _ port: Int) -> ProxyNode {
    ProxyNode(name: name, kind: .vless, server: "1.2.3.4", port: port, uuid: "u-\(name)")
}

@Test func autoModeEmitsBalancerObservatoryAndMultiOutbound() {
    let cands = [vless("A", 443), vless("B", 8443), vless("C", 2053)]
    let root = autoRoot(candidates: cands)
    #expect(root["stats"] != nil)
    let obs = (root["observatory"] as? [String: Any]) ?? [:]
    #expect(obs["probeInterval"] as? String == "30s")
    #expect((obs["subjectSelector"] as? [String])?.contains("proxy") == true)
    let obTags = ((root["outbounds"] as? [[String: Any]]) ?? []).compactMap { $0["tag"] as? String }
    #expect(obTags.contains("proxy1") && obTags.contains("proxy2") && obTags.contains("proxy3"))
    #expect(!obTags.contains("proxy"))   // 自动模式没有单 "proxy"
    let bal = (((root["routing"] as? [String: Any])?["balancers"] as? [[String: Any]])?.first) ?? [:]
    #expect(bal["tag"] as? String == "auto")
    #expect(((bal["selector"] as? [String])?.first) == "proxy")
    #expect(((bal["strategy"] as? [String: Any])?["type"]) as? String == "leastPing")
    let rules = (((root["routing"] as? [String: Any])?["rules"]) as? [[String: Any]]) ?? []
    #expect(rules.contains { ($0["balancerTag"] as? String) == "auto" })
}

@Test func manualModeHasNoBalancerOrObservatory() {
    let n = vless("A", 443)
    let root = (try? JSONSerialization.jsonObject(with: XrayConfigCompiler.compileData(
        node: n, runtime: .init(autoSwitch: false), candidates: [n]))) as? [String: Any] ?? [:]
    #expect(root["observatory"] == nil)
    #expect(root["stats"] == nil)
    let obTags = ((root["outbounds"] as? [[String: Any]]) ?? []).compactMap { $0["tag"] as? String }
    #expect(obTags.contains("proxy"))
    let bal = ((root["routing"] as? [String: Any])?["balancers"])
    #expect(bal == nil)
}

@Test func probeIntervalIsConfigurableAndFloored() {
    let c = [vless("A", 1), vless("B", 2)]
    let r1 = autoRoot(candidates: c, interval: 120)
    #expect(((r1["observatory"] as? [String: Any])?["probeInterval"]) as? String == "120s")
    let r2 = autoRoot(candidates: c, interval: 1)   // 低于下限 → 钳到 5
    #expect(((r2["observatory"] as? [String: Any])?["probeInterval"]) as? String == "5s")
}

@Test func singleCandidateAutoModeStillValid() {
    // 只勾一个候选也应能出合法配置（balancer over 1）
    let root = autoRoot(candidates: [vless("A", 443)])
    #expect(root["observatory"] != nil)
    let obTags = ((root["outbounds"] as? [[String: Any]]) ?? []).compactMap { $0["tag"] as? String }
    #expect(obTags.contains("proxy1"))
}

@Test func autoConfigBootsXray() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let vendor = repoRoot.appendingPathComponent("Vendor/xray")
    let xray = vendor.appendingPathComponent("xray")
    guard FileManager.default.isExecutableFile(atPath: xray.path) else { return }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("autocfg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    for f in ["geoip.dat", "geosite.dat"] {
        try? FileManager.default.createSymbolicLink(at: tmp.appendingPathComponent(f), withDestinationURL: vendor.appendingPathComponent(f))
    }
    let cands = [vless("A", 443), vless("B", 8443)]
    let cfg = tmp.appendingPathComponent("config.json")
    try XrayConfigCompiler.compileData(node: cands[0],
        runtime: .init(socksPort: 20990, httpPort: 20991, autoSwitch: true, probeIntervalSeconds: 10),
        candidates: cands).write(to: cfg)
    let p = Process(); p.executableURL = xray; p.arguments = ["run", "-c", cfg.path]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try p.run(); usleep(1_800_000)
    let died = !p.isRunning
    if p.isRunning { p.terminate(); p.waitUntilExit() }
    #expect(died == false, "自动切换(leastPing+observatory)配置应能被 xray 加载启动")
}
