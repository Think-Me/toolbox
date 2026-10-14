import Foundation
import Testing
@testable import ToolboxKit

private func ok(_ link: String) throws -> ProxyNode {
    switch NodeLinkParser.parse(link) {
    case .success(let n): return n
    case .failure(let e): throw e
    }
}

// MARK: vmess

@Test func parsesVmessFromBase64JSON() throws {
    let json: [String: Any] = [
        "v": "2", "ps": "东京-A", "add": "1.2.3.4", "port": "443",
        "id": "11111111-2222-3333-4444-555555555555", "aid": "0",
        "net": "ws", "host": "a.example.com", "path": "/ws", "tls": "tls", "sni": "a.example.com",
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    let link = "vmess://" + data.base64EncodedString()
    let n = try ok(link)
    #expect(n.kind == .vmess)
    #expect(n.name == "东京-A")
    #expect(n.server == "1.2.3.4")
    #expect(n.port == 443)
    #expect(n.uuid == "11111111-2222-3333-4444-555555555555")
    #expect(n.transport == .ws)
    #expect(n.host == "a.example.com")
    #expect(n.path == "/ws")
    #expect(n.useTLS)
    #expect(n.sni == "a.example.com")
}

@Test func vmessPortAsNumberAndNoTls() throws {
    let json: [String: Any] = ["ps": "n", "add": "h", "port": 8080, "id": "u", "net": "tcp"]
    let data = try JSONSerialization.data(withJSONObject: json)
    let n = try ok("vmess://" + data.base64EncodedString())
    #expect(n.port == 8080)
    #expect(n.useTLS == false)
    #expect(n.transport == .tcp)
    #expect(n.alterID == "0")     // aid 缺省补 0
}

@Test func vmessAcceptsURLSafeBase64WithoutPadding() throws {
    // 有些面板用 URL-safe 且去掉 '='
    let json: [String: Any] = ["ps": "x?y", "add": "1.1.1.1", "port": "1", "id": "i"]
    let b64 = try JSONSerialization.data(withJSONObject: json).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let n = try ok("vmess://" + b64)
    #expect(n.server == "1.1.1.1")
}

// MARK: vless

@Test func parsesVlessWithTlsAndWs() throws {
    let link = "vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443"
        + "?encryption=none&security=tls&sni=cf.example.com&type=ws&host=cf.example.com&path=%2Fvless#VLESS-%E6%97%A5%E6%9C%AC"
    let n = try ok(link)
    #expect(n.kind == .vless)
    #expect(n.uuid == "11111111-2222-3333-4444-555555555555")
    #expect(n.server == "1.2.3.4")
    #expect(n.port == 443)
    #expect(n.encryption == "none")
    #expect(n.useTLS && !n.isReality)
    #expect(n.sni == "cf.example.com")
    #expect(n.transport == .ws)
    #expect(n.path == "/vless")           // %2F 解码
    #expect(n.name == "VLESS-日本")        // fragment 百分号解码
}

@Test func parsesVlessReality() throws {
    let link = "vless://uuid-abc@1.2.3.4:8443?encryption=none&security=reality"
        + "&sni=www.microsoft.com&fp=chrome&pbk=PUBKEY&sid=SHORTID&flow=xtls-rprx-vision&type=tcp#R"
    let n = try ok(link)
    #expect(n.isReality && n.useTLS)
    #expect(n.publicKey == "PUBKEY")
    #expect(n.shortID == "SHORTID")
    #expect(n.flow == "xtls-rprx-vision")
    #expect(n.fingerprint == "chrome")
    #expect(n.transport == .tcp)
}

@Test func parsesVlessGrpcServiceName() throws {
    let link = "vless://u@h:443?security=tls&type=grpc&serviceName=grpcsvc&sni=h#G"
    let n = try ok(link)
    #expect(n.transport == .grpc)
    #expect(n.path == "grpcsvc")          // grpc 用 serviceName 当 path
}

// MARK: trojan

@Test func parsesTrojanPasswordAndWs() throws {
    let link = "trojan://secretpw@1.2.3.4:443?type=ws&path=%2Ftrojan&host=t.example.com&sni=t.example.com#T"
    let n = try ok(link)
    #expect(n.kind == .trojan)
    #expect(n.password == "secretpw")
    #expect(n.uuid.isEmpty)
    #expect(n.transport == .ws)
    #expect(n.path == "/trojan")
    #expect(n.useTLS)
}

// MARK: shadowsocks

@Test func parsesSSSIP002() throws {
    let methodPass = Data("chacha20-ietf-poly1305:pass123".utf8).base64EncodedString()
    let link = "ss://\(methodPass)@1.2.3.4:8388#SS-node"
    let n = try ok(link)
    #expect(n.kind == .shadowsocks)
    #expect(n.security == "chacha20-ietf-poly1305")
    #expect(n.password == "pass123")
    #expect(n.server == "1.2.3.4")
    #expect(n.port == 8388)
    #expect(n.name == "SS-node")
}

@Test func parsesSSLegacy() throws {
    let full = Data("aes-256-gcm:pw@9.9.9.9:4444".utf8).base64EncodedString()
    let n = try ok("ss://\(full)")
    #expect(n.security == "aes-256-gcm")
    #expect(n.password == "pw")
    #expect(n.server == "9.9.9.9")
    #expect(n.port == 4444)
    #expect(n.name == "SS")
}

@Test func ssPasswordWithSpecialChars() throws {
    // 密码里含 ':' 和 '@'：SIP002 里 base64 段不含 '@'，legacy 用最后一个 '@' 分界
    let mp = Data("aes-256-cbc:a:b@c:secret".utf8).base64EncodedString()
    let n = try ok("ss://\(mp)@1.2.3.4:1080")
    #expect(n.security == "aes-256-cbc")
    #expect(n.password == "a:b@c:secret")   // maxSplits:1 → 只按第一个 ':' 分
}

// MARK: 畸形输入

@Test func rejectsGarbageAndEmpty() {
    #expect(NodeLinkParser.parse("") == .failure(.empty))
    #expect(NodeLinkParser.parse("   ") == .failure(.empty))
    if case .failure(.unknownScheme) = NodeLinkParser.parse("http://x") {} else {
        Issue.record("http:// 应判为未知 scheme")
    }
    if case .failure(.badBase64) = NodeLinkParser.parse("vmess://!!!not base64!!!") {} else {
        Issue.record("坏 base64 应判 badBase64")
    }
    if case .failure(.malformed) = NodeLinkParser.parse("vless://u@host:notaport") {} else {
        Issue.record("端口非数字应判 malformed")
    }
}

@Test func trimsSurroundingWhitespace() throws {
    let link = "  trojan://pw@1.2.3.4:443  \n"
    let n = try ok(link)
    #expect(n.server == "1.2.3.4")
}

@Test func parsesVlessXhttpReality() throws {
    // 用户真实节点：vless + xhttp + reality。曾因 transport 不认 xhttp 退化成 tcp，
    // 导致服务器回 HTTP、报 "unexpected response version"。
    let link = "vless://uuid@derp.example.vip:8080?encryption=none&security=reality"
        + "&sni=tms.dingtalk.com&fp=chrome&type=xhttp&path=%2F&pbk=PUB&sid=71#BWH"
    let n = try ok(link)
    #expect(n.transport == .xhttp)
    #expect(n.isReality && n.useTLS)
    #expect(n.path == "/")
    #expect(n.publicKey == "PUB" && n.shortID == "71")
}
