using System.Text.Json;
using Xunit;
using Toolbox.Core.Proxy;

namespace Toolbox.Core.Tests;

/// <summary>
/// config 编译的 golden 断言。xray 对字段名/结构的错误是**静默**的（连不上但不报错），
/// 这里的每一行断言都是防回归的关键约束。
/// </summary>
public sealed class XrayConfigCompilerTests
{
    private static readonly ProxyNode Node = new()
    {
        Name = "测试",
        Kind = ProxyProtocolKind.Vmess,
        Server = "s.example.com",
        Port = 443,
        Uuid = "uuid-1",
        Security = "auto",
        Transport = ProxyTransport.Ws,
        Host = "cdn.example.com",
        Path = "/wspath",
        UseTls = true,
        Sni = "s.example.com",
    };

    private static readonly ProxyRuntimeSettings Runtime = new();

    private static ProxyRuntimeSettings Rt(Action<ProxyRuntimeSettings>? mutate = null)
    {
        var settings = new ProxyRuntimeSettings();
        mutate?.Invoke(settings);
        return settings;
    }

    private static JsonElement CompileJson(ProxyNode node, ProxyRuntimeSettings runtime,
                                           IReadOnlyList<ProxyNode>? candidates = null)
    {
        var json = XrayConfigCompiler.CompileJson(node, runtime, candidates);
        return JsonDocument.Parse(json).RootElement.Clone();
    }

    [Fact]
    public void InboundsExposeSocksAndHttpOnLoopback()
    {
        var root = CompileJson(Node, Rt(r =>
        {
            r.SocksPort = 10808;
            r.HttpPort = 10809;
        }));

        var inbounds = root.GetProperty("inbounds");
        Assert.Equal(2, inbounds.GetArrayLength());
        Assert.Equal(10808, inbounds[0].GetProperty("port").GetInt32());
        Assert.Equal("socks", inbounds[0].GetProperty("protocol").GetString());
        Assert.Equal("127.0.0.1", inbounds[0].GetProperty("listen").GetString());
        Assert.Equal(10809, inbounds[1].GetProperty("port").GetInt32());
        Assert.Equal("http", inbounds[1].GetProperty("protocol").GetString());
    }

    [Fact]
    public void ManualModeHasSingleProxyOutboundFirst()
    {
        var root = CompileJson(Node, Runtime);

        var outbounds = root.GetProperty("outbounds");
        Assert.Equal("proxy", outbounds[0].GetProperty("tag").GetString());
        Assert.Equal("vmess", outbounds[0].GetProperty("protocol").GetString());
        Assert.Equal("s.example.com", outbounds[0].GetProperty("settings")
            .GetProperty("vnext")[0].GetProperty("address").GetString());
        // alterId 是数字且来自字符串 aid
        Assert.Equal(0, outbounds[0].GetProperty("settings").GetProperty("vnext")[0]
            .GetProperty("users")[0].GetProperty("alterId").GetInt32());
    }

    /// <summary>xray 的规则键是单数 "protocol"（复数会静默失效）。</summary>
    [Fact]
    public void RoutingRuleUsesSingularProtocolKey()
    {
        var root = CompileJson(Node, Runtime);

        var dnsRule = root.GetProperty("routing").GetProperty("rules").EnumerateArray()
            .First(r => r.TryGetProperty("protocol", out _));
        Assert.Equal("dns", dnsRule.GetProperty("protocol")[0].GetString());
    }

    [Fact]
    public void BypassMainlandRoutesGeositeCnAndGeoipCnDirect()
    {
        var root = CompileJson(Node, Rt(r => r.RoutingMode = ProxyRoutingMode.BypassMainland));

        var rules = root.GetProperty("routing").GetProperty("rules").EnumerateArray().ToList();
        Assert.Contains(rules, r => r.TryGetProperty("domain", out var d) && d[0].GetString() == "geosite:cn"
                                    && r.GetProperty("outboundTag").GetString() == "direct");
        Assert.Contains(rules, r => r.TryGetProperty("ip", out var i) && i[0].GetString() == "geoip:cn"
                                    && r.GetProperty("outboundTag").GetString() == "direct");
    }

    /// <summary>GFW 模式默认出口必须是 direct（只有命中列表才代理）。</summary>
    [Fact]
    public void GfwListPutsDirectOutboundFirst()
    {
        var root = CompileJson(Node, Rt(r => r.RoutingMode = ProxyRoutingMode.GfwList));

        var outbounds = root.GetProperty("outbounds");
        Assert.Equal("direct", outbounds[0].GetProperty("tag").GetString());
        Assert.Contains(root.GetProperty("routing").GetProperty("rules").EnumerateArray(),
            r => r.TryGetProperty("domain", out var d) && d[0].GetString() == "geosite:gfw");
    }

    [Fact]
    public void AutoSwitchAddsBalancerObservatoryAndNumberedProxies()
    {
        var candidates = new List<ProxyNode>
        {
            Node,
            new() { Name = "备胎", Kind = ProxyProtocolKind.Trojan, Server = "t.example.com", Port = 443, Password = "pw" },
        };
        var root = CompileJson(Node, Rt(r => r.AutoSwitch = true), candidates);

        Assert.NotNull(root.TryGetProperty("observatory", out var obs) ? obs : null);
        Assert.Equal("30s", obs.GetProperty("probeInterval").GetString());

        var balancers = root.GetProperty("routing").GetProperty("balancers");
        Assert.Equal("auto", balancers[0].GetProperty("tag").GetString());
        Assert.Equal("leastPing", balancers[0].GetProperty("strategy").GetProperty("type").GetString());

        var outbounds = root.GetProperty("outbounds").EnumerateArray().ToList();
        Assert.Equal("proxy1", outbounds[0].GetProperty("tag").GetString());
        Assert.Equal("proxy2", outbounds[1].GetProperty("tag").GetString());
    }

    [Fact]
    public void RealityUsesRealitySettingsNotTls()
    {
        var realityNode = new ProxyNode
        {
            Kind = ProxyProtocolKind.Vless,
            Server = "r.example.com",
            Port = 443,
            Uuid = "u",
            IsReality = true,
            UseTls = true,      // reality 蕴含 TLS：解析器里 isReality → useTls
            PublicKey = "PBK",
            ShortId = "SID",
            Sni = "www.example.com",
            Fingerprint = "chrome",
        };
        var root = CompileJson(realityNode, Runtime);

        var stream = root.GetProperty("outbounds")[0].GetProperty("streamSettings");
        Assert.Equal("reality", stream.GetProperty("security").GetString());
        Assert.Equal("PBK", stream.GetProperty("realitySettings").GetProperty("publicKey").GetString());
        Assert.False(stream.TryGetProperty("tlsSettings", out _));
    }

    [Fact]
    public void PlainTcpWithoutTlsHasNoStreamSettings()
    {
        var plain = new ProxyNode { Kind = ProxyProtocolKind.Vmess, Server = "h", Port = 1, Uuid = "u" };
        var root = CompileJson(plain, Runtime);

        // WhenWritingNull 会整个省略 streamSettings 字段
        Assert.False(root.GetProperty("outbounds")[0].TryGetProperty("streamSettings", out _));
    }

    [Fact]
    public void ShadowsocksUsesMethodAndPassword()
    {
        var ss = new ProxyNode
        {
            Kind = ProxyProtocolKind.Shadowsocks,
            Server = "s",
            Port = 8388,
            Security = "aes-256-gcm",
            Password = "pw",
        };
        var root = CompileJson(ss, Runtime);

        var settings = root.GetProperty("outbounds")[0].GetProperty("settings");
        Assert.Equal("aes-256-gcm", settings.GetProperty("method").GetString());
        Assert.Equal("pw", settings.GetProperty("password").GetString());
    }

    /// <summary>xray 的 trojan outbound servers[] 必须自带 address/port（实测缺了起不来）。</summary>
    [Fact]
    public void TrojanServersCarryAddressAndPort()
    {
        var trojan = new ProxyNode
        {
            Kind = ProxyProtocolKind.Trojan,
            Server = "t.example.com",
            Port = 443,
            Password = "pw",
        };
        var root = CompileJson(trojan, Runtime);

        var server = root.GetProperty("outbounds")[0].GetProperty("settings").GetProperty("servers")[0];
        Assert.Equal("t.example.com", server.GetProperty("address").GetString());
        Assert.Equal(443, server.GetProperty("port").GetInt32());
        Assert.Equal("pw", server.GetProperty("password").GetString());
    }
}
