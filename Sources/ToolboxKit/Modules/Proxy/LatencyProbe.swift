import Foundation

/// 经本地 SOCKS 代理发一次真实请求测延迟。
/// 代理字典构造是纯函数（可测）；真正的网络往返只在用户点"测延迟"时发生，
/// 需要有一个能用的节点，所以不做单测，靠探针/人工验证。
public enum LatencyProbe {
    public enum Outcome: Equatable {
        case milliseconds(Int)
        case failed(String)
    }

    /// 默认打一个 204 端点（无 body、快、只测通路）
    public static let defaultURL = URL(string: "https://www.gstatic.com/generate_204")!

    public static func socksProxyDict(port: Int) -> [AnyHashable: Any] {
        [
            // 键名必须是 "SOCKSEnable"（不是 SOCKSEnabled）：写错的话 URLSession
            // 当没配代理、直连目标 → 国内直连 gstatic 被墙 → 报 SSL 错，
            // 表现成"代理不通"，其实是探针没走代理（实测踩过）。
            "SOCKSEnable": 1,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": port,
        ]
    }

    public static func httpProxyDict(port: Int) -> [AnyHashable: Any] {
        [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
            // https:// 资源（如 GitHub release）走的是 HTTPS 代理键，缺了它
            // HTTPS 请求会绕过代理直连 → 国内超时。两类都要设。
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
        ]
    }

    /// 经 HTTP 代理请求 url，返回耗时（ms）或失败原因。
    ///
    /// 用 HTTP 而不是 SOCKS：URLSession 走 SOCKS 会**本地先解析域名**再交给代理，
    /// 国内把 gstatic/google 解析成污染 IP → TLS 握手失败报 SSL 错，
    /// 明明代理是通的却测出"不通"。HTTP 代理的 CONNECT 带域名，由 xray 远端解析。
    public static func measureThroughProxy(port: Int, url: URL = defaultURL,
                                           timeout: TimeInterval = 5) async -> Outcome {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = httpProxyDict(port: port)
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        let start = Date()
        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (_, resp) = try await session.data(for: req)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                return .failed("HTTP \(http.statusCode)")
            }
            return .milliseconds(ms)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
