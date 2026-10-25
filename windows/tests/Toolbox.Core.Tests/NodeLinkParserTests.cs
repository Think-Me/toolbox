using Xunit;
using Toolbox.Core.Proxy;

namespace Toolbox.Core.Tests;

public sealed class NodeLinkParserTests
{
    private static string B64(string json) =>
        Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(json))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');

    // ---- vmess ----

    [Fact]
    public void VmessParsesBase64JsonWithUrlSafeAlphabet()
    {
        var json = """{"ps":"测试节点","add":"a.example.com","port":443,"id":"uuid-1","aid":0,"scy":"auto","net":"ws","host":"cdn.example.com","path":"/ws?x=1","tls":"tls","sni":"sni.example.com"}""";
        var node = NodeLinkParser.Parse("vmess://" + B64(json));

        Assert.Equal("测试节点", node.Name);
        Assert.Equal(ProxyProtocolKind.Vmess, node.Kind);
        Assert.Equal("a.example.com", node.Server);
        Assert.Equal(443, node.Port);
        Assert.Equal("uuid-1", node.Uuid);
        Assert.Equal("auto", node.Security);
        Assert.Equal("0", node.AlterId);
        Assert.Equal(ProxyTransport.Ws, node.Transport);
        Assert.Equal("cdn.example.com", node.Host);
        Assert.True(node.UseTls);
        Assert.Equal("sni.example.com", node.Sni);
    }

    [Fact]
    public void VmessNumberFieldsAreAccepted()
    {
        // 有些面板把 aid/port 发成数字：Str() 必须能读
        var json = """{"add":"h","port":8443,"id":"u","aid":64}""";
        var node = NodeLinkParser.Parse("vmess://" + B64(json));
        Assert.Equal("64", node.AlterId);
        Assert.Equal(8443, node.Port);
    }

    [Fact]
    public void VmessWithoutPortFails()
    {
        Assert.Throws<NodeParseException>(() =>
            NodeLinkParser.Parse("vmess://" + B64("""{"add":"h","id":"u"}""")));
    }

    // ---- vless ----

    [Fact]
    public void VlessRealityParsesQueryAndFragment()
    {
        var node = NodeLinkParser.Parse(
            "vless://uuid-2@v.example.com:443?security=reality&fp=chrome&pbk=PBK&sid=AB&sni=www.example.com&flow=xtls-rprx-vision&type=grpc&serviceName=GrpcSvc#我的节点");

        Assert.Equal("我的节点", node.Name);
        Assert.Equal(ProxyProtocolKind.Vless, node.Kind);
        Assert.Equal("uuid-2", node.Uuid);
        Assert.Equal("v.example.com", node.Server);
        Assert.Equal(443, node.Port);
        Assert.True(node.IsReality);
        Assert.True(node.UseTls);
        Assert.Equal("chrome", node.Fingerprint);
        Assert.Equal("PBK", node.PublicKey);
        Assert.Equal("AB", node.ShortId);
        Assert.Equal("xtls-rprx-vision", node.Flow);
        Assert.Equal(ProxyTransport.Grpc, node.Transport);
        Assert.Equal("GrpcSvc", node.Path);
    }

    [Fact]
    public void VlessWithoutExplicitSecurityIsNotTls()
    {
        var node = NodeLinkParser.Parse("vless://u@h:1?type=tcp");
        Assert.False(node.UseTls);
        Assert.False(node.IsReality);
    }

    // ---- trojan ----

    [Fact]
    public void TrojanDefaultsToTls()
    {
        var node = NodeLinkParser.Parse("trojan://secret@t.example.com:443?sni=t.example.com#trojan节点");
        Assert.Equal(ProxyProtocolKind.Trojan, node.Kind);
        Assert.Equal("secret", node.Password);
        Assert.True(node.UseTls);
        Assert.Equal("trojan节点", node.Name);
    }

    // ---- shadowsocks ----

    [Fact]
    public void SsSip002ParsesBase64Userinfo()
    {
        var userinfo = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("aes-256-gcm:pass1"));
        var node = NodeLinkParser.Parse($"ss://{userinfo.TrimEnd('=')}@s.example.com:8388#SS节点");

        Assert.Equal(ProxyProtocolKind.Shadowsocks, node.Kind);
        Assert.Equal("aes-256-gcm", node.Security);
        Assert.Equal("pass1", node.Password);
        Assert.Equal("s.example.com", node.Server);
        Assert.Equal(8388, node.Port);
        Assert.Equal("SS节点", node.Name);
    }

    [Fact]
    public void SsLegacyParsesFullyEncodedForm()
    {
        var whole = Convert.ToBase64String(
            System.Text.Encoding.UTF8.GetBytes("chacha20-ietf-poly1305:pass2@legacy.example.com:443"));
        var node = NodeLinkParser.Parse($"ss://{whole}");

        Assert.Equal("chacha20-ietf-poly1305", node.Security);
        Assert.Equal("pass2", node.Password);
        Assert.Equal("legacy.example.com", node.Server);
    }

    // ---- 边角 ----

    [Theory]
    [InlineData("")]
    [InlineData("https://example.com")]
    [InlineData("ss://!!!bad-base64!!!")]
    public void BadInputThrows(string raw)
    {
        if (raw.Length == 0)
            Assert.Throws<NodeParseException>(() => NodeLinkParser.Parse(raw));
        else
            Assert.ThrowsAny<Exception>(() => NodeLinkParser.Parse(raw));
    }

    [Fact]
    public void TryParseReturnsMessageInsteadOfThrowing()
    {
        Assert.NotNull(NodeLinkParser.TryParse("vmess://xxx", out _));
        Assert.Null(NodeLinkParser.TryParse(
            "vless://u@h:1", out var node));
        Assert.NotNull(node);
    }
}
