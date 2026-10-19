import Foundation

/// 一个 GitHub Release 里我们关心的信息。
public struct AppReleaseInfo: Equatable, Sendable {
    public var version: String        // 去掉前缀 v 的语义版本，如 "0.1.3"
    public var tag: String            // 原始 tag_name，如 "v0.1.3"
    public var dmgURL: String         // release 资产里的 .dmg 下载地址
    public var pageURL: String        // release 页面（用于"在浏览器打开"）
    public var notes: String
}

public enum AppUpdateStatus: Equatable, Sendable {
    case upToDate(current: String)
    case available(AppReleaseInfo)
    case failed(String)
}

public enum AppUpdater {
    /// 发布仓库。换仓库改这里。
    public static let repo = "Think-Me/toolbox"
    public static var latestAPI: String { "https://api.github.com/repos/\(repo)/releases/latest" }

    // MARK: 纯逻辑（可测）

    /// 从 GitHub releases/latest 的 JSON 解析出 AppReleaseInfo；没有 .dmg 资产返回 nil。
    public static func parseRelease(_ data: Data) -> AppReleaseInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        let assets = (obj["assets"] as? [[String: Any]]) ?? []
        guard let dmg = assets.first(where: {
            ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true
        }), let url = dmg["browser_download_url"] as? String else { return nil }
        return AppReleaseInfo(
            version: normalizeVersion(tag),
            tag: tag,
            dmgURL: url,
            pageURL: obj["html_url"] as? String ?? "https://github.com/\(repo)/releases/latest",
            notes: obj["body"] as? String ?? "")
    }

    /// "v0.1.3" / "0.1.3" → "0.1.3"
    public static func normalizeVersion(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// 套用 GitHub 加速镜像：镜像前缀 + 原始下载 URL（gh-proxy 类约定）。
    /// 镜像为空则原样返回。只在下载 github.com 资产时用；api.github.com 不走镜像。
    public static func downloadURL(for info: AppReleaseInfo, mirror: String) -> String {
        let m = mirror.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return info.dmgURL }
        let base = m.hasSuffix("/") ? m : m + "/"
        return base + info.dmgURL
    }

    /// 拿 fetcher 查最新版本并和当前版本比较。
    public static func check(currentVersion: String, settings: UpdateSettings,
                             fetcher: any HTTPFetching) async -> AppUpdateStatus {
        let url = URL(string: latestAPI)!   // 代理与否由 fetcher 决定，不改 URL
        do {
            let data = try await fetcher.get(url)
            guard let info = parseRelease(data) else {
                return .failed("没找到可下载的 .dmg 资产")
            }
            if ProxyVersion.isNewer(info.version, than: currentVersion) {
                return .available(info)
            }
            return .upToDate(current: currentVersion)
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: 下载 + 挂载 + 替换 + 重启（有副作用，靠探针/人工验证）

    public enum ApplyError: Error, Equatable {
        case download(String)
        case mount(String)
        case notFound(String)
        case swap(String)
    }

    /// 下载 dmg 并挂载，返回挂载点 URL。调用方负责 detach。
    public static func downloadAndMount(info: AppReleaseInfo, settings: UpdateSettings,
                                        fetcher: any HTTPFetching,
                                        progress: (@Sendable (Double) -> Void)? = nil)
        async throws -> (dmg: URL, mount: URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dmg = tmp.appendingPathComponent("Toolbox.dmg")
        let dl = downloadURL(for: info, mirror: settings.githubMirror)
        guard let u = URL(string: dl) else { throw ApplyError.download("URL 非法: \(dl)") }
        do { try await fetcher.download(u, to: dmg, progress: progress ?? { _ in }) }
        catch { throw ApplyError.download(String(describing: error)) }

        let out = runSync("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", dmg.path])
        guard let mountLine = out.split(separator: "\n").last(where: { $0.contains("/Volumes/") }),
              let mountPath = mountLine.split(separator: "\t").last.map(String.init)
        else { throw ApplyError.mount(out) }
        return (dmg, URL(fileURLWithPath: mountPath))
    }

    /// 挂载卷里找 Toolbox.app。
    public static func appInMount(_ mount: URL) -> URL? {
        let cand = mount.appendingPathComponent("Toolbox.app")
        return FileManager.default.fileExists(atPath: cand.path) ? cand : nil
    }

    /// 生成"替换 + 重启"脚本：等本进程退出后，用挂载卷里的新 app 覆盖当前 app，
    /// 清隔离、卸载镜像、重新打开。
    /// 之所以用外部脚本：运行中的 .app 不能可靠地原地覆盖自己，必须等进程退出再换。
    public static func swapScript(mountApp: URL, currentApp: URL, mount: URL, dmg: URL) -> String {
        """
        #!/bin/zsh
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        sleep 2
        /bin/rm -rf \(shq(currentApp.path))
        /bin/cp -R \(shq(mountApp.path)) \(shq(currentApp.path))
        /usr/bin/xattr -dr com.apple.quarantine \(shq(currentApp.path)) 2>/dev/null || true
        /usr/bin/hdiutil detach \(shq(mount.path)) >/dev/null 2>&1 || true
        /bin/rm -rf \(shq(dmg.deletingLastPathComponent().path))
        /usr/bin/open \(shq(currentApp.path))
        """
    }

    /// 卸载挂载点（失败也忽略，脚本里还会再 detach 一次）。
    @discardableResult
    public static func detach(_ mount: URL) -> Bool {
        runSync("/usr/bin/hdiutil", ["detach", "-force", mount.path]).contains("failed") == false
    }

    private static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func runSync(_ exe: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run(); p.waitUntilExit() } catch { return "err: \(error)" }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
