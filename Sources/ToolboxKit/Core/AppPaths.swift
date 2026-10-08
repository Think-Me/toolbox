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

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [root, mediaDirectory, hostsBackupDirectory, logsDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
