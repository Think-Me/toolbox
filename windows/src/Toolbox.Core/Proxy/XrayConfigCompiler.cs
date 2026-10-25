using System.Text.Json;
using System.Text.Json.Serialization;

namespace Toolbox.Core.Proxy;

/// <summary>
/// 生成 xray 的 config.json。用类型化结构建模而非手拼字典：
/// 字段名写错（尤其 protocol/alterId 这种大小写）编译器不会报，
/// 但 xray 会静默连不上——类型化 + golden 测试是唯一能锁住它的办法。
///
/// 关键约束（macOS 实测）：
/// - geoip 规则写成 "ip": ["geoip:cn"]、geosite 写成 "domain": ["geosite:cn"]；
///   独立的 "geoip" 字段本版本不认。
/// - 自动切换用 routing.balancers（leastPing）+ observatory；selector 是**前缀匹配**。
/// - fallbackTag 单独用会 "not all dependencies are resolved"，且 roundRobin 只轮询
///   不 failover——所以走 leastPing + observatory（探测间隔可配）。
/// </summary>
public static class XrayConfigCompiler
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };

    /// <summary>
    /// - node: 当前选中的节点（手动模式用）
    /// - candidates: 勾选进自动组的节点（自动模式用）
    /// </summary>
    public static XrayConfig Compile(ProxyNode node, ProxyRuntimeSettings runtime,
                                     IReadOnlyList<ProxyNode>? candidates = null)
    {
        var group = runtime.AutoSwitch
            ? (candidates is { Count: > 0 } ? candidates : [node])
            : [node];
        var auto = runtime.AutoSwitch;
        return new XrayConfig
        {
            Log = new XrayConfig.LogSection("warning"),
            Stats = auto ? new XrayConfig.StatsSection() : null,
            Observatory = auto
                ? new XrayConfig.ObservatorySection(["proxy"], $"{Math.Max(5, runtime.ProbeIntervalSeconds)}s")
                : null,
            Inbounds =
            [
                new XrayConfig.Inbound(
                    runtime.SocksPort, "socks", "127.0.0.1", "socks-in",
                    new XrayConfig.InboundSettings("noauth", true, "127.0.0.1")),
                new XrayConfig.Inbound(runtime.HttpPort, "http", "127.0.0.1", "http-in", null),
            ],
            Outbounds = Outbounds(group, auto, runtime.RoutingMode),
            Routing = Routing(runtime.RoutingMode, auto),
        };
    }

    public static string CompileJson(ProxyNode node, ProxyRuntimeSettings runtime,
                                     IReadOnlyList<ProxyNode>? candidates = null) =>
        JsonSerializer.Serialize(Compile(node, runtime, candidates), JsonOptions);

    // ---- outbound ----

    /// <summary>
    /// xray 用 outbounds 数组的**第一个**作默认出口。
    /// GFW 模式默认要 direct（只有命中 gfwlist 才代理），所以 direct 排最前；其余 proxy 在前。
    /// </summary>
    private static List<XrayConfig.Outbound> Outbounds(
        IReadOnlyList<ProxyNode> group, bool auto, ProxyRoutingMode mode)
    {
        var direct = new XrayConfig.Outbound("direct", "freedom", new XrayConfig.OutboundSettings(), null);
        var block = new XrayConfig.Outbound("block", "blackhole", new XrayConfig.OutboundSettings(), null);
        // 自动模式：proxy1、proxy2…（balancer 的 selector ["proxy"] 前缀匹配它们）
        // 手动模式：单个 "proxy"
        var proxies = auto
            ? group.Select((n, i) =>
            {
                var o = ProxyOutbound(n);
                o.Tag = $"proxy{i + 1}";
                return o;
            }).ToList()
            : [ProxyOutbound(group[0])];

        return mode == ProxyRoutingMode.GfwList
            ? [direct, .. proxies, block]
            : [.. proxies, direct, block];
    }

    private static XrayConfig.Outbound ProxyOutbound(ProxyNode node)
    {
        XrayConfig.OutboundSettings settings = node.Kind switch
        {
            ProxyProtocolKind.Vmess => new XrayConfig.OutboundSettings
            {
                Vnext =
                [
                    new XrayConfig.VNext(node.Server, node.Port,
                        [
                            new XrayConfig.VNextUser(node.Uuid,
                                int.TryParse(node.AlterId, out var aid) ? aid : 0,
                                node.Security.Length > 0 ? node.Security : "auto",
                                null, null),
                        ]),
                ],
            },
            ProxyProtocolKind.Vless => new XrayConfig.OutboundSettings
            {
                Vnext =
                [
                    new XrayConfig.VNext(node.Server, node.Port,
                        [
                            new XrayConfig.VNextUser(node.Uuid, null, null,
                                node.Encryption.Length > 0 ? node.Encryption : "none",
                                node.Flow.Length > 0 ? node.Flow : null),
                        ]),
                ],
            },
            ProxyProtocolKind.Trojan => new XrayConfig.OutboundSettings
            {
                Servers = [new XrayConfig.TrojanServer(node.Server, node.Port, node.Password, node.Name)],
            },
            _ => new XrayConfig.OutboundSettings
            {
                Address = node.Server,
                Port = node.Port,
                Method = node.Security.Length > 0 ? node.Security : "aes-256-gcm",
                Password = node.Password,
            },
        };

        return new XrayConfig.Outbound("proxy", node.Kind.XrayProtocol(), settings, StreamSettings(node));
    }

    private static XrayConfig.StreamSettings? StreamSettings(ProxyNode node)
    {
        if (node.Transport == ProxyTransport.Tcp && !node.UseTls) return null;

        var security = node.IsReality ? "reality" : node.UseTls ? "tls" : null;
        XrayConfig.TlsSettings? tls = null;
        XrayConfig.RealitySettings? reality = null;
        if (node.IsReality)
        {
            reality = new XrayConfig.RealitySettings(
                node.Sni.Length > 0 ? node.Sni : null,
                node.Fingerprint.Length > 0 ? node.Fingerprint : null,
                node.PublicKey,
                node.ShortId.Length > 0 ? node.ShortId : null);
        }
        else if (node.UseTls)
        {
            tls = new XrayConfig.TlsSettings(
                node.Sni.Length > 0 ? node.Sni : null,
                node.Fingerprint.Length > 0 ? node.Fingerprint : null);
        }

        XrayConfig.WsSettings? ws = node.Transport switch
        {
            ProxyTransport.Ws => new XrayConfig.WsSettings(
                node.Path.Length > 0 ? node.Path : "/", node.Host.Length > 0 ? node.Host : null),
            _ => null,
        };
        XrayConfig.GrpcSettings? grpc = node.Transport == ProxyTransport.Grpc
            ? new XrayConfig.GrpcSettings(node.Path.Length > 0 ? node.Path : "grpc")
            : null;
        XrayConfig.XhttpSettings? xhttp = node.Transport == ProxyTransport.Xhttp
            ? new XrayConfig.XhttpSettings(node.Path.Length > 0 ? node.Path : "/",
                node.Host.Length > 0 ? node.Host : null, "auto")
            : null;

        return new XrayConfig.StreamSettings(node.Transport.XrayNetwork(), security, tls, reality, ws, grpc, xhttp);
    }

    // ---- routing ----

    private static XrayConfig.RoutingSection Routing(ProxyRoutingMode mode, bool auto)
    {
        var rules = new List<XrayConfig.RoutingRule>
        {
            new("field", Ip: ["geoip:private"], Domain: null, Protocols: null, Network: null,
                OutboundTag: "direct", BalancerTag: null),
            new("field", Ip: null, Domain: null, Protocols: ["dns"], Network: null,
                OutboundTag: "direct", BalancerTag: null),
        };
        switch (mode)
        {
            case ProxyRoutingMode.BypassMainland:
                rules.Add(new XrayConfig.RoutingRule("field", Ip: null, Domain: ["geosite:cn"],
                    Protocols: null, Network: null, OutboundTag: "direct", BalancerTag: null));
                rules.Add(new XrayConfig.RoutingRule("field", Ip: ["geoip:cn"], Domain: null,
                    Protocols: null, Network: null, OutboundTag: "direct", BalancerTag: null));
                if (auto)
                {
                    // 其余流量走 balancer（leastPing 在候选里挑延迟最低/可用的）
                    rules.Add(new XrayConfig.RoutingRule("field", Ip: null, Domain: null,
                        Protocols: null, Network: "tcp,udp", OutboundTag: null, BalancerTag: "auto"));
                }
                break;

            case ProxyRoutingMode.GfwList:
                rules.Add(ProxyRule(["geosite:gfw"], auto));
                break;

            case ProxyRoutingMode.Global:
                if (auto)
                {
                    rules.Add(new XrayConfig.RoutingRule("field", Ip: null, Domain: null,
                        Protocols: null, Network: "tcp,udp", OutboundTag: null, BalancerTag: "auto"));
                }
                break;
        }

        var balancers = auto
            ? new List<XrayConfig.Balancer>
                { new("auto", ["proxy"], new XrayConfig.BalancerStrategy("leastPing")) }
            : null;
        return new XrayConfig.RoutingSection("AsIs") { Rules = rules, Balancers = balancers };
    }

    /// <summary>代理流量的目的地：自动模式指向 balancer "auto"，手动指向 outbound "proxy"。</summary>
    private static XrayConfig.RoutingRule ProxyRule(string[] domain, bool auto) =>
        new("field", Ip: null, Domain: domain, Protocols: null, Network: null,
            OutboundTag: auto ? null : "proxy", BalancerTag: auto ? "auto" : null);
}

/// <summary>xray config.json 的类型化模型。属性名即 JSON 字段名（camelCase）。</summary>
public sealed class XrayConfig
{
    public LogSection Log { get; init; } = new("warning");
    public StatsSection? Stats { get; init; }
    public ObservatorySection? Observatory { get; init; }
    public List<Inbound> Inbounds { get; init; } = [];
    public List<Outbound> Outbounds { get; init; } = [];
    public RoutingSection Routing { get; init; } = new();

    public sealed record LogSection(string Loglevel);
    public sealed class StatsSection;
    public sealed record ObservatorySection(string[] SubjectSelector, string ProbeInterval);

    public sealed record Inbound(int Port, string Protocol, string Listen, string? Tag, InboundSettings? Settings);
    public sealed record InboundSettings(string? Auth, bool? Udp, string? Ip);

    public sealed class Outbound(string tag, string protocol, OutboundSettings settings, StreamSettings? streamSettings)
    {
        public string Tag { get; set; } = tag;
        public string Protocol { get; } = protocol;
        public OutboundSettings Settings { get; } = settings;
        public StreamSettings? StreamSettings { get; } = streamSettings;
    }

    public sealed class OutboundSettings
    {
        public List<VNext>? Vnext { get; init; }
        public List<TrojanServer>? Servers { get; init; }
        public string? Address { get; init; }
        public int? Port { get; init; }
        public string? Method { get; init; }
        public string? Password { get; init; }
    }

    public sealed record VNext(string Address, int Port, List<VNextUser> Users);
    public sealed record VNextUser(string Id, int? AlterId, string? Security, string? Encryption, string? Flow);
    /// <summary>xray 的 trojan outbound 每台服务器必须自带 address/port（实测缺了报 "Trojan server address is not set"）。</summary>
    public sealed record TrojanServer(string Address, int Port, string Password, string? Email);

    public sealed record StreamSettings(
        string Network,
        string? Security,
        TlsSettings? TlsSettings,
        RealitySettings? RealitySettings,
        WsSettings? WsSettings,
        GrpcSettings? GrpcSettings,
        XhttpSettings? XhttpSettings);

    public sealed record TlsSettings(string? ServerName, string? Fingerprint);
    public sealed record RealitySettings(string? ServerName, string? Fingerprint, string PublicKey, string? ShortId);
    public sealed record WsSettings(string Path, string? Host);
    public sealed record GrpcSettings(string ServiceName);
    public sealed record XhttpSettings(string Path, string? Host, string? Mode);

    public sealed class RoutingSection(string domainStrategy = "AsIs")
    {
        public string DomainStrategy { get; } = domainStrategy;
        public List<RoutingRule> Rules { get; init; } = [];
        public List<Balancer>? Balancers { get; init; }
    }

    public sealed record RoutingRule(
        string Type,
        string[]? Ip,
        string[]? Domain,
        // xray 的规则键是单数 "protocol"，不能让 camelCase 策略把它写成 "protocols"
        [property: JsonPropertyName("protocol")] string[]? Protocols,
        string? Network,
        string? OutboundTag,
        string? BalancerTag);

    public sealed record Balancer(string Tag, string[] Selector, BalancerStrategy Strategy);
    public sealed record BalancerStrategy(string Type);
}
