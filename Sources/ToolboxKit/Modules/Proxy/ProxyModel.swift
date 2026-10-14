import Foundation

public enum ProxyProtocolKind: String, Codable, Sendable, CaseIterable, Equatable {
    case vmess, vless, trojan, shadowsocks

    /// xray outbound 的 protocol 名
    public var xrayProtocol: String {
        switch self {
        case .vmess: return "vmess"
        case .vless: return "vless"
        case .trojan: return "trojan"
        case .shadowsocks: return "shadowsocks"
        }
    }
}

public enum ProxyTransport: String, Codable, Sendable, Equatable {
    case tcp, ws, grpc, http, xhttp

    /// xray streamSettings.network
    public var xrayNetwork: String { rawValue }
    public static let defaultTransport: ProxyTransport = .tcp
}

/// 一个代理节点。字段刻意做平（照 v2rayN 的存法），而不是每协议一个子结构：
/// 编译 config 时按 kind 取用需要的字段，缺失的用默认值，模型层不用背四套类型。
public struct ProxyNode: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProxyProtocolKind
    public var server: String
    public var port: Int
    /// vmess/vless 的 uuid；trojan/shadowsocks 用 password
    public var uuid: String
    public var password: String
    /// vmess/vless 的 cipher（auto / chacha20-poly1305 …）；shadowsocks 的 method
    public var security: String
    public var alterID: String          // vmess aid
    public var flow: String             // vless flow（xtls-rprx-vision）
    public var encryption: String       // vless encryption（通常 none）
    public var transport: ProxyTransport
    public var host: String             // ws/grpc 的 Host
    public var path: String             // ws path / grpc serviceName
    public var useTLS: Bool
    public var sni: String
    public var fingerprint: String      // tls fingerprint（chrome/…）
    public var isReality: Bool          // security=reality
    public var publicKey: String        // reality pbk
    public var shortID: String          // reality sid

    public init(id: UUID = UUID(), name: String, kind: ProxyProtocolKind,
                server: String, port: Int, uuid: String = "", password: String = "",
                security: String = "", alterID: String = "0", flow: String = "",
                encryption: String = "none", transport: ProxyTransport = .tcp,
                host: String = "", path: String = "", useTLS: Bool = false,
                sni: String = "", fingerprint: String = "", isReality: Bool = false,
                publicKey: String = "", shortID: String = "") {
        self.id = id; self.name = name; self.kind = kind; self.server = server
        self.port = port; self.uuid = uuid; self.password = password
        self.security = security; self.alterID = alterID; self.flow = flow
        self.encryption = encryption; self.transport = transport
        self.host = host; self.path = path; self.useTLS = useTLS
        self.sni = sni; self.fingerprint = fingerprint
        self.isReality = isReality; self.publicKey = publicKey; self.shortID = shortID
    }

    // 宽松解码：每个字段都 decodeIfPresent 给默认值。
    // 未来给 ProxyNode 加字段时，老库缺这些字段也能解，不会整份失败被重置。
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, server, port, uuid, password, security, alterID, flow,
             encryption, transport, host, path, useTLS, sni, fingerprint,
             isReality, publicKey, shortID
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ t: T.Type, _ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(t, forKey: k)) ?? nil ?? fallback
        }
        id = d(UUID.self, .id, UUID())
        name = d(String.self, .name, "节点")
        kind = d(ProxyProtocolKind.self, .kind, .vmess)
        server = d(String.self, .server, "")
        port = d(Int.self, .port, 0)
        uuid = d(String.self, .uuid, "")
        password = d(String.self, .password, "")
        security = d(String.self, .security, "")
        alterID = d(String.self, .alterID, "0")
        flow = d(String.self, .flow, "")
        encryption = d(String.self, .encryption, "none")
        transport = d(ProxyTransport.self, .transport, .tcp)
        host = d(String.self, .host, "")
        path = d(String.self, .path, "")
        useTLS = d(Bool.self, .useTLS, false)
        sni = d(String.self, .sni, "")
        fingerprint = d(String.self, .fingerprint, "")
        isReality = d(Bool.self, .isReality, false)
        publicKey = d(String.self, .publicKey, "")
        shortID = d(String.self, .shortID, "")
    }

    /// 列表里显示的摘要
    public var summary: String {
        "\(kind.rawValue) · \(server):\(port) · \(transport.rawValue)\(useTLS ? " · tls" : "")"
    }
}

/// 路由模式。
public enum ProxyRoutingMode: String, Codable, Sendable, CaseIterable, Equatable {
    case global          // 全局：一切走代理
    case bypassMainland  // 绕过大陆：大陆 IP/域名直连，其余走代理
    case gfwList         // GFW 列表：只有命中 gfwlist 的走代理，其余直连

    public var label: String {
        switch self {
        case .global: return "全局（全部走代理）"
        case .bypassMainland: return "绕过大陆（大陆直连，其余代理）"
        case .gfwList: return "GFW 列表（仅列表内走代理）"
        }
    }
}

/// 代理运行配置（端口等）。端口默认对齐机器上已存在的 10808 习惯。
public struct ProxyRuntimeSettings: Codable, Equatable, Sendable {
    public var socksPort: Int
    public var httpPort: Int
    public var routingMode: ProxyRoutingMode

    public init(socksPort: Int = 10808, httpPort: Int = 10809,
                routingMode: ProxyRoutingMode = .bypassMainland) {
        self.socksPort = socksPort; self.httpPort = httpPort; self.routingMode = routingMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        socksPort = (try? c.decodeIfPresent(Int.self, forKey: .socksPort)) ?? nil ?? 10808
        httpPort = (try? c.decodeIfPresent(Int.self, forKey: .httpPort)) ?? nil ?? 10809
        routingMode = (try? c.decodeIfPresent(ProxyRoutingMode.self, forKey: .routingMode)) ?? nil ?? .bypassMainland
    }
    private enum CodingKeys: String, CodingKey { case socksPort, httpPort, routingMode }
}
