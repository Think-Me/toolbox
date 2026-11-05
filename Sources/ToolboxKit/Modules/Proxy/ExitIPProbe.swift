import Darwin
import Foundation

/// 查询本机当前的出口 IP：一次直连、一次经本地代理，用于对照。
public enum ExitIPProbe {
    /// 依次尝试，首个返回可用 IP 的端点胜出。优先选国内可达的纯文本端点，
    /// 这样直连（不翻墙）也能拿到结果。
    public static let endpoints: [URL] = [
        URL(string: "https://myip.ipip.net")!,
        URL(string: "https://api.ipify.org?format=json")!,
        URL(string: "https://ifconfig.me/ip")!,
    ]

    /// 不经过任何代理（包括系统代理）时的出口 IP。
    public static func direct() async -> String? {
        await fetch(proxyPort: nil)
    }

    /// 经本地 HTTP 代理时的出口 IP（即当前节点的落地 IP）。
    public static func viaProxy(httpPort: Int) async -> String? {
        await fetch(proxyPort: httpPort)
    }

    /// 解析响应体：优先取 JSON 的 `ip` 字段，否则从文本里抓第一个 IP。
    public static func parse(_ data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ip = obj["ip"] as? String, !ip.isEmpty {
            return ip
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return firstIP(in: text)
    }

    static func firstIP(in text: String) -> String? {
        // 先粗抓候选，再用 inet_pton 校验——正则本身无法可靠判断 IPv6 的「::」缩写
        let patterns = [
            #"(?:\d{1,3}\.){3}\d{1,3}"#,
            #"[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}"#,
        ]
        let ns = text as NSString
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                let candidate = ns.substring(with: match.range)
                if isIPAddress(candidate) { return candidate }
            }
        }
        return nil
    }

    static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 { return true }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 { return true }
        return false
    }

    private static func fetch(proxyPort: Int?) async -> String? {
        for url in endpoints {
            if let data = await request(url, proxyPort: proxyPort), let ip = parse(data) {
                return ip
            }
        }
        return nil
    }

    private static func request(_ url: URL, proxyPort: Int?) async -> Data? {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 8
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let proxyPort {
            cfg.connectionProxyDictionary = LatencyProbe.httpProxyDict(port: proxyPort)
        } else {
            // 关键：必须显式设成空字典才绕过系统代理。nil 表示沿用系统代理，
            // 用户开了「设为系统代理」时直连 IP 会等于代理 IP，失去对照意义。
            cfg.connectionProxyDictionary = [:]
        }
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return data
    }
}
