using System.Text;
using System.Text.Json;

namespace Toolbox.Core.Proxy;

public enum NodeParseErrorKind
{
    Empty,
    UnknownScheme,
    Malformed,
    BadBase64,
}

/// <summary>解析失败：kind + 给用户看的说明。</summary>
public sealed class NodeParseException(NodeParseErrorKind kind, string message) : Exception(message)
{
    public NodeParseErrorKind Kind { get; } = kind;
}

/// <summary>
/// 把分享链接（vmess:// / vless:// / trojan:// / ss://）解析成 ProxyNode。
/// 纯函数、不碰网络——链接格式来自各家面板，边角（base64 补位、URL-safe 字母表、
/// ss 的 SIP002 vs legacy、reality 参数）错了就表现为「粘贴进去没反应」或「连不上」。
/// </summary>
public static class NodeLinkParser
{
    public static ProxyNode Parse(string raw)
    {
        var s = raw.Trim();
        if (s.Length == 0) throw new NodeParseException(NodeParseErrorKind.Empty, "链接为空");

        var lower = s.ToLowerInvariant();
        if (lower.StartsWith("vmess://")) return ParseVmess(s[8..]);
        if (lower.StartsWith("vless://")) return ParseUserAuth(s[8..], ProxyProtocolKind.Vless);
        if (lower.StartsWith("trojan://")) return ParseUserAuth(s[9..], ProxyProtocolKind.Trojan);
        if (lower.StartsWith("ss://")) return ParseSS(s[5..]);

        throw new NodeParseException(NodeParseErrorKind.UnknownScheme,
            $"无法识别的链接：{s[..Math.Min(12, s.Length)]}");
    }

    /// <summary>返回 null 表示解析成功；否则是给用户看的错误说明。</summary>
    public static string? TryParse(string raw, out ProxyNode? node)
    {
        node = null;
        try
        {
            node = Parse(raw);
            return null;
        }
        catch (NodeParseException error)
        {
            return error.Message;
        }
    }

    // ---- 基础工具 ----

    internal static byte[] Base64Decode(string s)
    {
        var t = s.Trim().Replace('-', '+').Replace('_', '/');
        var remainder = t.Length % 4;
        if (remainder > 0) t += new string('=', 4 - remainder);
        return Convert.FromBase64String(t);
    }

    internal static string PercentDecode(string s) =>
        Uri.UnescapeDataString(s.Replace("+", "%20"));

    internal static ProxyTransport TransportFor(string net) => net.ToLowerInvariant() switch
    {
        "ws" or "websocket" => ProxyTransport.Ws,
        "grpc" or "gun" => ProxyTransport.Grpc,
        "http" or "h2" => ProxyTransport.Http,
        // v2rayN 新节点常用 xhttp；raw 是别名
        "xhttp" or "raw" => ProxyTransport.Xhttp,
        _ => ProxyTransport.Tcp,
    };

    internal static Dictionary<string, string> ParseQuery(string q)
    {
        var dict = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in q.Split('&'))
        {
            var kv = pair.Split('=', 2);
            if (kv.Length == 2) dict[kv[0]] = kv[1];
        }
        return dict;
    }

    private static string Str(JsonElement obj, string key)
    {
        if (!obj.TryGetProperty(key, out var value)) return "";
        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString() ?? "",
            JsonValueKind.Number => value.GetRawText(),
            _ => "",
        };
    }

    // ---- vmess ----

    private static ProxyNode ParseVmess(string body)
    {
        JsonElement obj;
        try
        {
            using var doc = JsonDocument.Parse(Base64Decode(body));
            obj = doc.RootElement.Clone();
        }
        catch
        {
            throw new NodeParseException(NodeParseErrorKind.BadBase64, "链接解码失败");
        }

        if (!int.TryParse(Str(obj, "port"), out var port) || port <= 0)
            throw new NodeParseException(NodeParseErrorKind.Malformed, "链接格式有误：vmess 缺端口");

        var aid = Str(obj, "aid");
        var cipher = Str(obj, "scy").Length > 0 ? Str(obj, "scy") : Str(obj, "security");
        var name = Str(obj, "ps").Length > 0 ? Str(obj, "ps") : Str(obj, "name");

        return new ProxyNode
        {
            Name = name.Length > 0 ? name : "VMess",
            Kind = ProxyProtocolKind.Vmess,
            Server = Str(obj, "add"),
            Port = port,
            Uuid = Str(obj, "id"),
            Security = cipher,
            AlterId = aid.Length > 0 ? aid : "0",
            Transport = TransportFor(Str(obj, "net")),
            Host = Str(obj, "host"),
            Path = PercentDecode(Str(obj, "path")),
            UseTls = Str(obj, "tls").ToLowerInvariant() == "tls",
            Sni = Str(obj, "sni"),
        };
    }

    // ---- vless / trojan（同为 user@host:port?query#frag 结构） ----

    private static ProxyNode ParseUserAuth(string body, ProxyProtocolKind kind)
    {
        var rest = body;
        var name = "";
        var hash = rest.IndexOf('#');
        if (hash >= 0)
        {
            name = PercentDecode(rest[(hash + 1)..]);
            rest = rest[..hash];
        }
        var query = "";
        var question = rest.IndexOf('?');
        if (question >= 0)
        {
            query = rest[(question + 1)..];
            rest = rest[..question];
        }
        var userinfo = "";
        var at = rest.IndexOf('@');
        if (at >= 0)
        {
            userinfo = rest[..at];
            rest = rest[(at + 1)..];
        }
        var colon = rest.LastIndexOf(':');
        if (colon < 0)
            throw new NodeParseException(NodeParseErrorKind.Malformed, "链接格式有误：缺 host:port");
        var server = rest[..colon];
        if (!int.TryParse(rest[(colon + 1)..], out var port) || port <= 0)
            throw new NodeParseException(NodeParseErrorKind.Malformed, "链接格式有误：端口非法");

        var p = ParseQuery(query);
        var security = (p.TryGetValue("security", out var sec) ? sec : "").ToLowerInvariant();
        var isReality = security == "reality";
        // trojan 本质就是 TLS 协议，链接常省略 security=tls → 默认开；
        // vless 则只有显式 tls/reality 才算 TLS
        var useTls = isReality || security == "tls" || (kind == ProxyProtocolKind.Trojan && security != "none");

        var node = new ProxyNode
        {
            Name = name.Length > 0 ? name : (kind == ProxyProtocolKind.Vless ? "VLESS" : "Trojan"),
            Kind = kind,
            Server = server,
            Port = port,
            Uuid = kind == ProxyProtocolKind.Vless ? userinfo : "",
            Password = kind == ProxyProtocolKind.Trojan ? PercentDecode(userinfo) : "",
            Transport = TransportFor(p.TryGetValue("type", out var type) ? type : "tcp"),
            Host = p.TryGetValue("host", out var host) ? host : "",
            Path = PercentDecode(p.TryGetValue("path", out var path) ? path :
                                 p.TryGetValue("serviceName", out var sn) ? sn : ""),
            UseTls = useTls,
            Sni = p.TryGetValue("sni", out var sni) ? sni : "",
            Fingerprint = p.TryGetValue("fp", out var fp) ? fp : "",
            IsReality = isReality,
            PublicKey = p.TryGetValue("pbk", out var pbk) ? pbk : "",
            ShortId = p.TryGetValue("sid", out var sid) ? sid : "",
        };
        if (kind == ProxyProtocolKind.Vless)
        {
            node.Encryption = p.TryGetValue("encryption", out var enc) ? enc : "none";
            node.Flow = p.TryGetValue("flow", out var flow) ? flow : "";
        }
        return node;
    }

    // ---- shadowsocks（SIP002 与 legacy 两种） ----

    private static ProxyNode ParseSS(string body)
    {
        var rest = body;
        var name = "";
        var hash = rest.IndexOf('#');
        if (hash >= 0)
        {
            name = PercentDecode(rest[(hash + 1)..]);
            rest = rest[..hash];
        }

        string methodPass;
        string hostPort;
        int at;
        if ((at = rest.IndexOf('@')) >= 0)
        {
            // base64 字母表不含 '@'，所以第一个 '@' 之前必是 base64（SIP002）
            string decoded;
            try { decoded = Encoding.UTF8.GetString(Base64Decode(rest[..at])); }
            catch { throw new NodeParseException(NodeParseErrorKind.BadBase64, "链接解码失败"); }
            methodPass = decoded;
            hostPort = rest[(at + 1)..];
        }
        else
        {
            // 没有 '@' 则整段是 base64（legacy）
            string full;
            try { full = Encoding.UTF8.GetString(Base64Decode(rest)); }
            catch { throw new NodeParseException(NodeParseErrorKind.BadBase64, "链接解码失败"); }
            var legacyAt = full.LastIndexOf('@');
            if (legacyAt < 0)
                throw new NodeParseException(NodeParseErrorKind.Malformed, "链接格式有误：ss 缺 @");
            methodPass = full[..legacyAt];
            hostPort = full[(legacyAt + 1)..];
        }

        var mpSplit = methodPass.Split(':', 2);
        if (mpSplit.Length != 2)
            throw new NodeParseException(NodeParseErrorKind.Malformed, "链接格式有误：ss method:password");
        var colon = hostPort.LastIndexOf(':');
        if (colon < 0)
            throw new NodeParseException(NodeParseErrorKind.Malformed, "链接格式有误：ss host:port");
        var server = hostPort[..colon];
        if (!int.TryParse(hostPort[(colon + 1)..], out var port) || port <= 0)
            throw new NodeParseException(NodeParseErrorKind.Malformed, "链接格式有误：ss 端口非法");

        return new ProxyNode
        {
            Name = name.Length > 0 ? name : "SS",
            Kind = ProxyProtocolKind.Shadowsocks,
            Server = server,
            Port = port,
            Password = mpSplit[1],
            Security = mpSplit[0],
        };
    }
}
