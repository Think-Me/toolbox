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
    case tcp, ws, grpc, http

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

    /// 列表里显示的摘要
    public var summary: String {
        "\(kind.rawValue) · \(server):\(port) · \(transport.rawValue)\(useTLS ? " · tls" : "")"
    }
}

/// 路由模式。
public enum ProxyRoutingMode: String, Codable, Sendable, CaseIterable, Equatable {
    case global          // 全局：一切走代理
    case bypassMainland  // 绕过大陆：大陆 IP/域名直连，其余走代理
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
}
