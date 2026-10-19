import Foundation

/// 软件自更新的设置。
public struct UpdateSettings: Codable, Equatable, Sendable {
    /// 启动时 + 每隔 checkIntervalHours 自动查一次更新
    public var autoCheck: Bool
    /// 自动检查间隔（小时）
    public var checkIntervalHours: Int
    /// 检查/下载走本地 HTTP 代理（GitHub 国内直连常失败）
    public var useProxy: Bool
    /// 代理端口（HTTP 代理）
    public var proxyPort: Int
    /// GitHub 加速镜像前缀（如 https://ghproxy.net/）。非空时，下载 URL 前缀它。
    /// 只对 github.com 的 release 下载有效；api.github.com 的探测仍走代理/直连。
    public var githubMirror: String

    public init(autoCheck: Bool = true, checkIntervalHours: Int = 24,
                useProxy: Bool = false, proxyPort: Int = 10809, githubMirror: String = "") {
        self.autoCheck = autoCheck; self.checkIntervalHours = checkIntervalHours
        self.useProxy = useProxy; self.proxyPort = proxyPort; self.githubMirror = githubMirror
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoCheck = (try? c.decodeIfPresent(Bool.self, forKey: .autoCheck)) ?? nil ?? true
        checkIntervalHours = (try? c.decodeIfPresent(Int.self, forKey: .checkIntervalHours)) ?? nil ?? 24
        useProxy = (try? c.decodeIfPresent(Bool.self, forKey: .useProxy)) ?? nil ?? false
        proxyPort = (try? c.decodeIfPresent(Int.self, forKey: .proxyPort)) ?? nil ?? 10809
        githubMirror = (try? c.decodeIfPresent(String.self, forKey: .githubMirror)) ?? nil ?? ""
    }
    private enum CodingKeys: String, CodingKey {
        case autoCheck, checkIntervalHours, useProxy, proxyPort, githubMirror
    }
}
