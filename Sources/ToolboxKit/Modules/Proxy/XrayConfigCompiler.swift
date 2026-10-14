import Foundation

/// 生成 xray 的 config.json。用 Codable 结构体建模而非手拼字典：
/// 字段名写错（尤其 `protocol`/`alterId` 这种大小写）编译器不会报，
/// 但 xray 会静默连不上——类型化 + golden 测试是唯一能锁住它的办法。
///
/// 关键约束（spec §1.1 #34）：geoip 规则必须写成 `"ip": ["geoip:cn"]`，
/// geosite 写成 `"domain": ["geosite:cn"]`；独立的 `"geoip"` 字段本版本不认。
public enum XrayConfigCompiler {

    public static func compile(node: ProxyNode, runtime: ProxyRuntimeSettings) -> XrayConfig {
        XrayConfig(
            log: .init(loglevel: "warning"),
            inbounds: [
                .init(port: runtime.socksPort, protocol: "socks", listen: "127.0.0.1",
                      tag: "socks-in",
                      settings: .init(auth: "noauth", udp: true, ip: "127.0.0.1")),
                .init(port: runtime.httpPort, protocol: "http", listen: "127.0.0.1",
                      tag: "http-in", settings: nil),
            ],
            outbounds: [
                proxyOutbound(node: node),
                .init(tag: "direct", protocol: "freedom", settings: .empty, streamSettings: nil),
                .init(tag: "block", protocol: "blackhole", settings: .empty, streamSettings: nil),
            ],
            routing: routing(mode: runtime.routingMode))
    }

    public static func compileData(node: ProxyNode, runtime: ProxyRuntimeSettings) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        // 结构体全是内置类型，编码不会失败
        return (try? enc.encode(compile(node: node, runtime: runtime))) ?? Data()
    }

    // MARK: outbound

    private static func proxyOutbound(node: ProxyNode) -> XrayConfig.Outbound {
        let settings: XrayConfig.OutboundSettings
        switch node.kind {
        case .vmess:
            settings = .init(vnext: [.init(address: node.server, port: node.port, users: [
                .init(id: node.uuid, alterId: Int(node.alterID) ?? 0,
                      security: node.security.isEmpty ? "auto" : node.security,
                      encryption: nil, flow: nil)])])
        case .vless:
            settings = .init(vnext: [.init(address: node.server, port: node.port, users: [
                .init(id: node.uuid, alterId: nil, security: nil,
                      encryption: node.encryption.isEmpty ? "none" : node.encryption,
                      flow: node.flow.isEmpty ? nil : node.flow)])])
        case .trojan:
            settings = .init(servers: [.init(password: node.password, email: node.name)])
        case .shadowsocks:
            settings = .init(address: node.server, port: node.port,
                             method: node.security.isEmpty ? "aes-256-gcm" : node.security,
                             password: node.password)
        }
        return .init(tag: "proxy", protocol: node.kind.xrayProtocol, settings: settings,
                     streamSettings: streamSettings(node: node))
    }

    private static func streamSettings(node: ProxyNode) -> XrayConfig.StreamSettings? {
        guard node.transport != .tcp || node.useTLS else { return nil }
        let security: String? = node.isReality ? "reality" : (node.useTLS ? "tls" : nil)
        var tls: XrayConfig.StreamSettings.TLSSettings?
        var reality: XrayConfig.StreamSettings.RealitySettings?
        if node.isReality {
            reality = .init(serverName: node.sni.isEmpty ? nil : node.sni,
                            fingerprint: node.fingerprint.isEmpty ? nil : node.fingerprint,
                            publicKey: node.publicKey, shortId: node.shortID.isEmpty ? nil : node.shortID)
        } else if node.useTLS {
            tls = .init(serverName: node.sni.isEmpty ? nil : node.sni,
                        fingerprint: node.fingerprint.isEmpty ? nil : node.fingerprint)
        }
        var ws: XrayConfig.StreamSettings.WsSettings?
        var grpc: XrayConfig.StreamSettings.GrpcSettings?
        var xhttp: XrayConfig.StreamSettings.XhttpSettings?
        switch node.transport {
        case .ws:
            ws = .init(path: node.path.isEmpty ? "/" : node.path,
                       host: node.host.isEmpty ? nil : node.host)
        case .grpc:
            grpc = .init(serviceName: node.path.isEmpty ? "grpc" : node.path)
        case .xhttp:
            xhttp = .init(path: node.path.isEmpty ? "/" : node.path,
                          host: node.host.isEmpty ? nil : node.host, mode: "auto")
        default: break
        }
        return .init(network: node.transport.xrayNetwork, security: security,
                     tlsSettings: tls, realitySettings: reality, wsSettings: ws,
                     grpcSettings: grpc, xhttpSettings: xhttp)
    }

    // MARK: routing

    private static func routing(mode: ProxyRoutingMode) -> XrayConfig.Routing {
        var rules: [XrayConfig.Routing.Rule] = [
            // 私网/回环永远直连（否则连局域网设备都走代理）
            .init(type: "field", ip: ["geoip:private"], domain: nil, protocols: nil, outboundTag: "direct"),
            // DNS 查询直连，避免解析被代理污染
            .init(type: "field", ip: nil, domain: nil, protocols: ["dns"], outboundTag: "direct"),
        ]
        if mode == .bypassMainland {
            rules.append(.init(type: "field", ip: nil, domain: ["geosite:cn"], protocols: nil, outboundTag: "direct"))
            rules.append(.init(type: "field", ip: ["geoip:cn"], domain: nil, protocols: nil, outboundTag: "direct"))
        }
        return .init(domainStrategy: "AsIs", rules: rules)
    }
}

// MARK: - config 结构

public struct XrayConfig: Encodable {
    public let log: Log
    public let inbounds: [Inbound]
    public let outbounds: [Outbound]
    public let routing: Routing

    public struct Log: Encodable { public let loglevel: String }

    public struct Inbound: Encodable {
        public let port: Int
        public let `protocol`: String
        public let listen: String
        public let tag: String?
        public let settings: Settings?
        public struct Settings: Encodable {
            public let auth: String?
            public let udp: Bool?
            public let ip: String?
        }
    }

    public struct Outbound: Encodable {
        public let tag: String
        public let `protocol`: String
        public let settings: OutboundSettings
        public let streamSettings: StreamSettings?
    }

    public struct OutboundSettings: Encodable {
        public var vnext: [VNext]?
        public var servers: [TrojanServer]?
        public var address: String?
        public var port: Int?
        public var method: String?
        public var password: String?
        // 计算属性而非 static let：后者是全局可变状态，Swift 6 并发检查会拦
        public static var empty: OutboundSettings { OutboundSettings() }
        public struct VNext: Encodable {
            public let address: String
            public let port: Int
            public let users: [User]
            public struct User: Encodable {
                public let id: String
                public let alterId: Int?
                public let security: String?
                public let encryption: String?
                public let flow: String?
            }
        }
        public struct TrojanServer: Encodable {
            public let password: String
            public let email: String?
        }
    }

    public struct StreamSettings: Encodable {
        public let network: String
        public let security: String?
        public let tlsSettings: TLSSettings?
        public let realitySettings: RealitySettings?
        public let wsSettings: WsSettings?
        public let grpcSettings: GrpcSettings?
        public let xhttpSettings: XhttpSettings?
        public struct XhttpSettings: Encodable {
            public let path: String
            public let host: String?
            public let mode: String?
        }
        public struct TLSSettings: Encodable {
            public let serverName: String?
            public let fingerprint: String?
        }
        public struct RealitySettings: Encodable {
            public let serverName: String?
            public let fingerprint: String?
            public let publicKey: String
            public let shortId: String?
        }
        public struct WsSettings: Encodable {
            public let path: String
            public let host: String?
            enum CodingKeys: String, CodingKey { case path, host }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(path, forKey: .path)
                if let host { try c.encode(host, forKey: .host) }
            }
        }
        public struct GrpcSettings: Encodable {
            public let serviceName: String
        }
    }

    public struct Routing: Encodable {
        public let domainStrategy: String
        public let rules: [Rule]
        public struct Rule: Encodable {
            public let type: String
            public let ip: [String]?
            public let domain: [String]?
            public let protocols: [String]?
            public let outboundTag: String
            enum CodingKeys: String, CodingKey {
                case type, ip, domain, outboundTag
                case protocols = "protocol"
            }
        }
    }
}
