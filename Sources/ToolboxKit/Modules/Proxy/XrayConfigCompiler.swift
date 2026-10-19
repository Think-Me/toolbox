import Foundation

/// 生成 xray 的 config.json。用 Codable 结构体建模而非手拼字典：
/// 字段名写错（尤其 `protocol`/`alterId` 这种大小写）编译器不会报，
/// 但 xray 会静默连不上——类型化 + golden 测试是唯一能锁住它的办法。
///
/// 关键约束（实测，见 spec §1.1 #34/#37）：
/// - geoip 规则写成 `"ip": ["geoip:cn"]`、geosite 写成 `"domain": ["geosite:cn"]`；
///   独立的 `"geoip"` 字段本版本不认。
/// - 自动切换用 `routing.balancers`（leastPing）+ `observatory`；`selector` 是**前缀匹配**。
/// - `fallbackTag` 单独用会 "not all dependencies are resolved"，且 roundRobin 只轮询
///   不 failover——所以走 leastPing + observatory（探测间隔可配）。
public enum XrayConfigCompiler {

    /// - Parameters:
    ///   - node: 当前选中的节点（手动模式用）
    ///   - candidates: 勾选进自动组的节点（自动模式用）
    public static func compile(node: ProxyNode, runtime: ProxyRuntimeSettings,
                               candidates: [ProxyNode] = []) -> XrayConfig {
        let group = runtime.autoSwitch ? (candidates.isEmpty ? [node] : candidates) : [node]
        let auto = runtime.autoSwitch && group.count >= 1
        return XrayConfig(
            log: .init(loglevel: "warning"),
            stats: auto ? .init() : nil,
            observatory: auto ? .init(subjectSelector: ["proxy"],
                                      probeInterval: "\(max(5, runtime.probeIntervalSeconds))s") : nil,
            inbounds: [
                .init(port: runtime.socksPort, protocol: "socks", listen: "127.0.0.1",
                      tag: "socks-in",
                      settings: .init(auth: "noauth", udp: true, ip: "127.0.0.1")),
                .init(port: runtime.httpPort, protocol: "http", listen: "127.0.0.1",
                      tag: "http-in", settings: nil),
            ],
            outbounds: outbounds(group: group, auto: auto, mode: runtime.routingMode),
            routing: routing(mode: runtime.routingMode, auto: auto))
    }

    public static func compileData(node: ProxyNode, runtime: ProxyRuntimeSettings,
                                   candidates: [ProxyNode] = []) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? enc.encode(compile(node: node, runtime: runtime, candidates: candidates))) ?? Data()
    }

    // MARK: outbound

    /// xray 用 outbounds 数组的**第一个**作默认出口。
    /// GFW 模式默认要 direct（只有命中 gfwlist 才代理），所以 direct 排最前；其余 proxy 在前。
    private static func outbounds(group: [ProxyNode], auto: Bool,
                                  mode: ProxyRoutingMode) -> [XrayConfig.Outbound] {
        let direct = XrayConfig.Outbound(tag: "direct", protocol: "freedom", settings: .empty, streamSettings: nil)
        let block = XrayConfig.Outbound(tag: "block", protocol: "blackhole", settings: .empty, streamSettings: nil)
        // 自动模式：proxy1、proxy2…（balancer 的 selector ["proxy"] 前缀匹配它们）
        // 手动模式：单个 "proxy"
        let proxies: [XrayConfig.Outbound]
        if auto {
            proxies = group.enumerated().map { (i, n) in
                var o = proxyOutbound(node: n); o.tag = "proxy\(i + 1)"; return o
            }
        } else {
            proxies = [proxyOutbound(node: group.first ?? group[0])]
        }
        switch mode {
        case .gfwList: return [direct] + proxies + [block]
        default:       return proxies + [direct, block]
        }
    }

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
            ws = .init(path: node.path.isEmpty ? "/" : node.path, host: node.host.isEmpty ? nil : node.host)
        case .grpc:
            grpc = .init(serviceName: node.path.isEmpty ? "grpc" : node.path)
        case .xhttp:
            xhttp = .init(path: node.path.isEmpty ? "/" : node.path, host: node.host.isEmpty ? nil : node.host, mode: "auto")
        default: break
        }
        return .init(network: node.transport.xrayNetwork, security: security,
                     tlsSettings: tls, realitySettings: reality, wsSettings: ws,
                     grpcSettings: grpc, xhttpSettings: xhttp)
    }

    // MARK: routing

    /// 代理流量的目的地：自动模式指向 balancer "auto"，手动指向 outbound "proxy"。
    private static func proxyRule(_ extra: (ip: [String]?, domain: [String]?),
                                  auto: Bool) -> XrayConfig.Routing.Rule {
        XrayConfig.Routing.Rule(type: "field", ip: extra.ip, domain: extra.domain, protocols: nil,
                                network: nil,
                                outboundTag: auto ? nil : "proxy", balancerTag: auto ? "auto" : nil)
    }

    private static func routing(mode: ProxyRoutingMode, auto: Bool) -> XrayConfig.Routing {
        var rules: [XrayConfig.Routing.Rule] = [
            .init(type: "field", ip: ["geoip:private"], domain: nil, protocols: nil, network: nil, outboundTag: "direct", balancerTag: nil),
            .init(type: "field", ip: nil, domain: nil, protocols: ["dns"], network: nil, outboundTag: "direct", balancerTag: nil),
        ]
        switch mode {
        case .bypassMainland:
            rules.append(.init(type: "field", ip: nil, domain: ["geosite:cn"], protocols: nil, network: nil, outboundTag: "direct", balancerTag: nil))
            rules.append(.init(type: "field", ip: ["geoip:cn"], domain: nil, protocols: nil, network: nil, outboundTag: "direct", balancerTag: nil))
            if auto {
                // 其余流量走 balancer（leastPing 在候选里挑延迟最低/可用的）
                rules.append(.init(type: "field", ip: nil, domain: nil, protocols: nil, network: "tcp,udp", outboundTag: nil, balancerTag: "auto"))
            }
        case .gfwList:
            rules.append(proxyRule((nil, ["geosite:gfw"]), auto: auto))
        case .global:
            if auto {
                rules.append(.init(type: "field", ip: nil, domain: nil, protocols: nil, network: "tcp,udp", outboundTag: nil, balancerTag: "auto"))
            }
        }
        let balancers: [XrayConfig.Routing.Balancer]? = auto ? [
            .init(tag: "auto", selector: ["proxy"], strategy: .init(type: "leastPing"))
        ] : nil
        return .init(domainStrategy: "AsIs", rules: rules, balancers: balancers)
    }
}

// MARK: - config 结构

public struct XrayConfig: Encodable {
    public let log: Log
    public let stats: Stats?
    public let observatory: Observatory?
    public let inbounds: [Inbound]
    public let outbounds: [Outbound]
    public let routing: Routing

    public struct Log: Encodable { public let loglevel: String }
    public struct Stats: Encodable {}
    public struct Observatory: Encodable {
        public let subjectSelector: [String]
        public let probeInterval: String
    }

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
        public var tag: String
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
        public struct GrpcSettings: Encodable { public let serviceName: String }
        public struct XhttpSettings: Encodable {
            public let path: String
            public let host: String?
            public let mode: String?
        }
    }

    public struct Routing: Encodable {
        public let domainStrategy: String
        public let rules: [Rule]
        public let balancers: [Balancer]?
        public struct Rule: Encodable {
            public let type: String
            public let ip: [String]?
            public let domain: [String]?
            public let protocols: [String]?
            public let network: String?
            public let outboundTag: String?
            public let balancerTag: String?
            enum CodingKeys: String, CodingKey {
                case type, ip, domain, network, outboundTag, balancerTag
                case protocols = "protocol"
            }
        }
        public struct Balancer: Encodable {
            public let tag: String
            public let selector: [String]
            public let strategy: Strategy
            public struct Strategy: Encodable { public let type: String }
        }
    }
}
