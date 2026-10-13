import Foundation

public enum NodeParseError: Error, Equatable {
    case empty
    case unknownScheme(String)
    case malformed(String)
    case badBase64
}

/// 把分享链接（vmess:// / vless:// / trojan:// / ss://）解析成 ProxyNode。
/// 纯函数、不碰网络，是 M5 里最值得测的一块——链接格式来自各家面板，
/// 边角（base64 补位、URL-safe 字母表、ss 的 SIP002 vs legacy、reality 参数）
/// 错了就表现为"粘贴进去没反应"或"连不上"。
public enum NodeLinkParser {

    public static func parse(_ raw: String) -> Result<ProxyNode, NodeParseError> {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .failure(.empty) }
        let lower = s.lowercased()
        if lower.hasPrefix("vmess://")  { return parseVmess(String(s.dropFirst(8))) }
        if lower.hasPrefix("vless://")  { return parseUserAuth(String(s.dropFirst(8)), kind: .vless) }
        if lower.hasPrefix("trojan://") { return parseUserAuth(String(s.dropFirst(9)), kind: .trojan) }
        if lower.hasPrefix("ss://")     { return parseSS(String(s.dropFirst(5))) }
        return .failure(.unknownScheme(String(s.prefix(12))))
    }

    // MARK: 基础工具

    static func base64Decode(_ s: String) -> Data? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = t.count % 4
        if rem > 0 { t += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: t)
    }

    static func percentDecode(_ s: String) -> String { s.removingPercentEncoding ?? s }

    static func transport(for net: String) -> ProxyTransport {
        switch net.lowercased() {
        case "ws", "websocket": return .ws
        case "grpc", "gun":     return .grpc
        case "http", "h2":      return .http
        default:                return .tcp
        }
    }

    static func parseQuery(_ q: String) -> [String: String] {
        var d: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            d[String(kv[0])] = String(kv[1])
        }
        return d
    }

    // MARK: vmess

    private static func parseVmess(_ body: String) -> Result<ProxyNode, NodeParseError> {
        guard let data = base64Decode(body),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .failure(.badBase64) }
        func str(_ k: String) -> String {
            if let v = obj[k] as? String { return v }
            if let n = obj[k] as? NSNumber { return n.stringValue }
            return ""
        }
        guard let port = Int(str("port")), port > 0 else { return .failure(.malformed("vmess 缺端口")) }
        let aid = str("aid").isEmpty ? "0" : str("aid")
        let cypher = str("scy").isEmpty ? str("security") : str("scy")
        let name = str("ps").isEmpty ? str("name") : str("ps")
        return .success(ProxyNode(
            name: name.isEmpty ? "VMess" : name,
            kind: .vmess, server: str("add"), port: port,
            uuid: str("id"), security: cypher, alterID: aid,
            transport: transport(for: str("net")),
            host: str("host"), path: percentDecode(str("path")),
            useTLS: str("tls").lowercased() == "tls",
            sni: str("sni")))
    }

    // MARK: vless / trojan（同为 user@host:port?query#frag 结构）

    private static func parseUserAuth(_ body: String, kind: ProxyProtocolKind)
        -> Result<ProxyNode, NodeParseError> {
        var rest = body
        var name = ""
        if let h = rest.firstIndex(of: "#") {
            name = percentDecode(String(rest[rest.index(after: h)...]))
            rest = String(rest[..<h])
        }
        var query = ""
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...])
            rest = String(rest[..<q])
        }
        var userinfo = ""
        if let at = rest.firstIndex(of: "@") {
            userinfo = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        guard let colon = rest.lastIndex(of: ":") else { return .failure(.malformed("缺 host:port")) }
        let server = String(rest[..<colon])
        guard let port = Int(String(rest[rest.index(after: colon)...])), port > 0 else {
            return .failure(.malformed("端口非法"))
        }
        let p = parseQuery(query)
        let security = (p["security"] ?? "").lowercased()
        let isReality = security == "reality"
        // trojan 本质就是 TLS 协议，链接常省略 security=tls → 默认开；
        // vless 则只有显式 tls/reality 才算 TLS
        let useTLS = isReality || security == "tls" || (kind == .trojan && security != "none")
        var node = ProxyNode(
            name: name.isEmpty ? (kind == .vless ? "VLESS" : "Trojan") : name,
            kind: kind, server: server, port: port,
            uuid: kind == .vless ? userinfo : "",
            password: kind == .trojan ? percentDecode(userinfo) : "",
            transport: transport(for: p["type"] ?? "tcp"),
            host: p["host"] ?? "",
            path: percentDecode(p["path"] ?? p["serviceName"] ?? ""),
            useTLS: useTLS,
            sni: p["sni"] ?? "",
            fingerprint: p["fp"] ?? "",
            isReality: isReality,
            publicKey: p["pbk"] ?? "",
            shortID: p["sid"] ?? "")
        if kind == .vless {
            node.encryption = p["encryption"] ?? "none"
            node.flow = p["flow"] ?? ""
        }
        return .success(node)
    }

    // MARK: shadowsocks（SIP002 与 legacy 两种）

    private static func parseSS(_ body: String) -> Result<ProxyNode, NodeParseError> {
        var rest = body
        var name = ""
        if let h = rest.firstIndex(of: "#") {
            name = percentDecode(String(rest[rest.index(after: h)...]))
            rest = String(rest[..<h])
        }
        // base64 字母表不含 '@'，所以第一个 '@' 之前必是 base64（SIP002）；
        // 没有 '@' 则整段是 base64（legacy）
        let methodPass: Substring
        let hostPort: String
        if let at = rest.firstIndex(of: "@") {
            guard let d = base64Decode(String(rest[..<at])),
                  let mp = String(data: d, encoding: .utf8) else { return .failure(.badBase64) }
            methodPass = Substring(mp)
            hostPort = String(rest[rest.index(after: at)...])
        } else {
            guard let d = base64Decode(rest),
                  let full = String(data: d, encoding: .utf8) else { return .failure(.badBase64) }
            guard let at = full.lastIndex(of: "@") else { return .failure(.malformed("ss legacy 缺 @")) }
            methodPass = Substring(full[..<at])
            hostPort = String(full[full.index(after: at)...])
        }
        let parts = methodPass.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .failure(.malformed("ss method:password")) }
        guard let colon = hostPort.lastIndex(of: ":") else { return .failure(.malformed("ss host:port")) }
        let server = String(hostPort[..<colon])
        guard let port = Int(String(hostPort[hostPort.index(after: colon)...])), port > 0 else {
            return .failure(.malformed("ss 端口非法"))
        }
        return .success(ProxyNode(name: name.isEmpty ? "SS" : name, kind: .shadowsocks,
                                  server: server, port: port,
                                  password: String(parts[1]), security: String(parts[0])))
    }
}
