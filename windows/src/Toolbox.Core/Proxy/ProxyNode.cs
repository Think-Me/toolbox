namespace Toolbox.Core.Proxy;

public enum ProxyProtocolKind
{
    Vmess,
    Vless,
    Trojan,
    Shadowsocks,
}

public enum ProxyTransport
{
    Tcp,
    Ws,
    Grpc,
    Http,
    Xhttp,
}

/// <summary>路由模式。</summary>
public enum ProxyRoutingMode
{
    Global,
    BypassMainland,
    GfwList,
}

public static class ProxyKindExtensions
{
    /// <summary>xray outbound 的 protocol 名。</summary>
    public static string XrayProtocol(this ProxyProtocolKind kind) => kind switch
    {
        ProxyProtocolKind.Vmess => "vmess",
        ProxyProtocolKind.Vless => "vless",
        ProxyProtocolKind.Trojan => "trojan",
        _ => "shadowsocks",
    };

    /// <summary>xray streamSettings.network。</summary>
    public static string XrayNetwork(this ProxyTransport transport) => transport switch
    {
        ProxyTransport.Tcp => "tcp",
        ProxyTransport.Ws => "ws",
        ProxyTransport.Grpc => "grpc",
        ProxyTransport.Http => "http",
        _ => "xhttp",
    };

    public static string Label(this ProxyRoutingMode mode) => mode switch
    {
        ProxyRoutingMode.Global => "全局（全部走代理）",
        ProxyRoutingMode.BypassMainland => "绕过大陆（大陆直连，其余代理）",
        _ => "GFW 列表（仅列表内走代理）",
    };
}

/// <summary>
/// 一个代理节点。字段刻意做平（照 v2rayN 的存法），而不是每协议一个子结构：
/// 编译 config 时按 kind 取用需要的字段，缺失的用默认值，模型层不用背四套类型。
/// </summary>
public sealed class ProxyNode
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "节点";
    public ProxyProtocolKind Kind { get; set; } = ProxyProtocolKind.Vmess;
    public string Server { get; set; } = "";
    public int Port { get; set; }
    /// <summary>vmess/vless 的 uuid；trojan/shadowsocks 用 password。</summary>
    public string Uuid { get; set; } = "";
    public string Password { get; set; } = "";
    /// <summary>vmess/vless 的 cipher（auto / chacha20-poly1305 …）；shadowsocks 的 method。</summary>
    public string Security { get; set; } = "";
    /// <summary>vmess aid。</summary>
    public string AlterId { get; set; } = "0";
    /// <summary>vless flow（xtls-rprx-vision）。</summary>
    public string Flow { get; set; } = "";
    /// <summary>vless encryption（通常 none）。</summary>
    public string Encryption { get; set; } = "none";
    public ProxyTransport Transport { get; set; } = ProxyTransport.Tcp;
    /// <summary>ws/grpc 的 Host。</summary>
    public string Host { get; set; } = "";
    /// <summary>ws path / grpc serviceName。</summary>
    public string Path { get; set; } = "";
    public bool UseTls { get; set; }
    public string Sni { get; set; } = "";
    /// <summary>tls fingerprint（chrome/…）。</summary>
    public string Fingerprint { get; set; } = "";
    /// <summary>security=reality。</summary>
    public bool IsReality { get; set; }
    /// <summary>reality pbk。</summary>
    public string PublicKey { get; set; } = "";
    /// <summary>reality sid。</summary>
    public string ShortId { get; set; } = "";
    /// <summary>是否加入「自动切换」候选组。仅 autoSwitch 模式用到。</summary>
    public bool BalancerCandidate { get; set; } = true;

    /// <summary>列表里显示的摘要。</summary>
    public string Summary =>
        $"{Kind.ToString().ToLowerInvariant()} · {Server}:{Port} · {Transport.ToString().ToLowerInvariant()}{(UseTls ? " · tls" : "")}";
}

/// <summary>代理运行配置（端口等）。端口默认对齐 10808/10809 习惯。</summary>
public sealed class ProxyRuntimeSettings
{
    public int SocksPort { get; set; } = 10808;
    public int HttpPort { get; set; } = 10809;
    public ProxyRoutingMode RoutingMode { get; set; } = ProxyRoutingMode.BypassMainland;
    /// <summary>
    /// 关=手动（用选中的单个节点）；开=自动切换（候选里按延迟 leastPing 选，
    /// 靠 observatory 探测——只在代理运行时才探，空闲不探）。
    /// </summary>
    public bool AutoSwitch { get; set; }
    /// <summary>observatory 探测间隔（秒），可配。</summary>
    public int ProbeIntervalSeconds { get; set; } = 30;
}

/// <summary>代理库：节点列表 + 当前选中节点 + 运行时设置。整体存一个 JSON。</summary>
public sealed class ProxyLibrary
{
    public List<ProxyNode> Nodes { get; set; } = [];
    public Guid? ActiveNodeId { get; set; }
    public ProxyRuntimeSettings Runtime { get; set; } = new();

    public ProxyNode? ActiveNode =>
        ActiveNodeId is { } id ? Nodes.FirstOrDefault(n => n.Id == id) : null;
}
