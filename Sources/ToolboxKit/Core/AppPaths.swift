import Foundation

/// 数据目录布局。全部路径从可注入的 root 派生，单测用 /tmp 下的临时目录。
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static let bundleIdentifier = "com.ebertwiseman.toolbox"

    /// ~/Library/Application Support/Toolbox
    public static func standard() -> AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return AppPaths(root: base.appendingPathComponent("Toolbox", isDirectory: true))
    }

    public var database: URL { root.appendingPathComponent("Toolbox") }
    public var mediaDirectory: URL { root.appendingPathComponent("Media", isDirectory: true) }
    public var settings: URL { root.appendingPathComponent("settings.json") }
    public var hostsRules: URL { root.appendingPathComponent("Hosts/rules.json") }
    public var hostsOriginal: URL { root.appendingPathComponent("Hosts/original-hosts") }
    public var hostsBackupDirectory: URL { root.appendingPathComponent("Hosts/backup", isDirectory: true) }
    public var logsDirectory: URL { root.appendingPathComponent("logs", isDirectory: true) }
    /// M5 代理：xray 内核 + geoip/geosite.dat + 生成的 config.json 都放这里。
    /// 必须在可写目录（不能写进 .app bundle），且 .dat 要和 config.json 同目录 ——
    /// xray 按 config 文件所在目录解析 geoip.dat（spec §1.1 #35）。
    public var proxyDirectory: URL { root.appendingPathComponent("Proxy", isDirectory: true) }
    public var proxyLibrary: URL { root.appendingPathComponent("Proxy/nodes.json") }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [root, mediaDirectory, hostsBackupDirectory, logsDirectory, proxyDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
