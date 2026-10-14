import Foundation

/// 拉取 URL 的抽象（注入假实现测 check 逻辑；真实用 URLSession）。
public protocol HTTPFetching: Sendable {
    func get(_ url: URL) async throws -> Data
    /// 下载到 file；progress 回调 0...1（Content-Length 未知时不回调）。
    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

public struct URLSessionFetcher: HTTPFetching {
    /// 走本地 HTTP 代理取 GitHub（国内直连常被墙/超时）。nil = 直连。
    public let proxyPort: Int?
    public init(proxyPort: Int? = nil) { self.proxyPort = proxyPort }

    private func makeSession() -> URLSession {
        guard let proxyPort else { return URLSession.shared }
        let cfg = URLSessionConfiguration.ephemeral
        // 用 HTTP 代理而非 SOCKS：HTTP CONNECT 把域名交给 xray 远端解析，
        // 避开 URLSession 走 SOCKS 时本地 DNS 被污染的问题（§1.1 #38）
        cfg.connectionProxyDictionary = LatencyProbe.httpProxyDict(port: proxyPort)
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        return URLSession(configuration: cfg)
    }

    public func get(_ url: URL) async throws -> Data {
        let (data, _) = try await makeSession().data(from: url)
        return data
    }

    /// 下载到 file，边下边报进度。用 delegate 式 URLSession：
    /// `download(from:)` 要等整个文件下完才返回、无进度；`AsyncBytes` 逐字节又太慢。
    public func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let cfg: URLSessionConfiguration
        if let proxyPort {
            cfg = .ephemeral
            cfg.connectionProxyDictionary = LatencyProbe.httpProxyDict(port: proxyPort)
        } else {
            cfg = .ephemeral
        }
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let delegate = DownloadDelegate(file: file, progress: progress, cont: cont)
            let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            session.downloadTask(with: url).resume()
        }
    }
}

/// 下载代理：didWriteData 报进度，didFinish 落盘，didComplete 收尾。
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let file: URL
    private let progress: @Sendable (Double) -> Void
    private let cont: CheckedContinuation<Void, Error>
    private var finished = false
    weak var session: URLSession?

    init(file: URL, progress: @escaping @Sendable (Double) -> Void,
         cont: CheckedContinuation<Void, Error>) {
        self.file = file; self.progress = progress; self.cont = cont
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten written: Int64,
                    totalBytesExpectedToWrite expected: Int64) {
        if expected > 0 { progress(Double(written) / Double(expected)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            try FileManager.default.moveItem(at: location, to: file)
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) } else { finish(.success(())) }
        session.finishTasksAndInvalidate()
    }

    private func finish(_ r: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        cont.resume(with: r)
    }
}

/// xray 内核 / geoip·geosite 规则库的更新检查与应用。
///
/// 端点固定为官方 GitHub release。规则库用 Loyalsoldier/v2ray-rules-dat
/// （v2rayN 同源），xray 用 XTLS/Xray-core。
public enum UpdateEndpoints {
    public static let xrayAPI = URL(string: "https://api.github.com/repos/XTLS/Xray-core/releases/latest")!
    public static let rulesAPI = URL(string: "https://api.github.com/repos/Loyalsoldier/v2ray-rules-dat/releases/latest")!
    public static func xrayZip(_ tag: String) -> URL {
        URL(string: "https://github.com/XTLS/Xray-core/releases/download/\(tag)/Xray-macos-arm64-v8a.zip")!
    }
    public static func rulesFile(_ tag: String, _ name: String) -> URL {
        URL(string: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/\(tag)/\(name)")!
    }
}

public struct UpdateInfo: Equatable, Sendable {
    public var coreCurrent: String
    public var coreLatest: String?
    public var rulesCurrent: String?
    public var rulesLatest: String?
    public var coreUpdateAvailable: Bool { ProxyVersion.isNewer(coreLatest, than: coreCurrent) }
    public var rulesUpdateAvailable: Bool { ProxyVersion.isNewer(rulesLatest, than: rulesCurrent) }
}

public enum UpdateService {
    public enum UpdateError: Error, Equatable {
        case network(String)
        case noRelease
        case applyFailed(String)
    }

    /// 从 GitHub release JSON 里取 tag_name（纯函数，可测）。
    public static func tag(fromReleaseJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        return tag
    }

    public static func currentVersions(paths: AppPaths) -> (core: String, rules: String?) {
        let fm = FileManager.default
        func read(_ name: String) -> String? {
            guard let d = fm.contents(atPath: paths.proxyDirectory.appendingPathComponent(name).path)
            else { return nil }
            return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (read(XrayBootstrap.coreStampName) ?? "未知", read("rules-version"))
    }

    public static func check(paths: AppPaths = .standard(), fetcher: any HTTPFetching = URLSessionFetcher()) async -> UpdateInfo {
        let cur = currentVersions(paths: paths)
        async let coreTag = latestTag(UpdateEndpoints.xrayAPI, fetcher)
        async let rulesTag = latestTag(UpdateEndpoints.rulesAPI, fetcher)
        return UpdateInfo(coreCurrent: cur.core, coreLatest: await coreTag,
                          rulesCurrent: cur.rules, rulesLatest: await rulesTag)
    }

    private static func latestTag(_ url: URL, _ fetcher: any HTTPFetching) async -> String? {
        guard let data = try? await fetcher.get(url) else { return nil }
        return tag(fromReleaseJSON: data)
    }

    // MARK: 应用更新

    /// 更新规则库：下载最新 geoip.dat + geosite.dat 覆盖到工作目录，写版本戳。
    public static func applyRulesUpdate(tag: String, paths: AppPaths = .standard(),
                                        fetcher: any HTTPFetching = URLSessionFetcher(),
                                        progress: (@Sendable (Double) -> Void)? = nil) async -> Result<Void, UpdateError> {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)")
        let files = XrayBootstrap.ruleFiles
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            for (i, name) in files.enumerated() {
                try await fetcher.download(UpdateEndpoints.rulesFile(tag, name),
                                           to: tmp.appendingPathComponent(name)) { p in
                    progress?((Double(i) + p) / Double(files.count))
                }
            }
            for name in files {
                let dst = paths.proxyDirectory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
                try FileManager.default.copyItem(at: tmp.appendingPathComponent(name), to: dst)
            }
            try tag.write(to: paths.proxyDirectory.appendingPathComponent("rules-version"), atomically: true, encoding: .utf8)
            progress?(1)
            return .success(())
        } catch {
            return .failure(.applyFailed(String(describing: error)))
        }
    }

    /// 更新内核：下载 zip、解压出 xray、覆盖工作目录二进制、写版本戳。
    /// 运行中的 xray 进程持有旧 inode，替换文件安全；调用方需重启内核才生效。
    public static func applyCoreUpdate(tag: String, paths: AppPaths = .standard(),
                                       fetcher: any HTTPFetching = URLSessionFetcher(),
                                       progress: (@Sendable (Double) -> Void)? = nil) async -> Result<Void, UpdateError> {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xray-\(UUID().uuidString)")
        let zip = tmp.appendingPathComponent("xray.zip")
        let ex = tmp.appendingPathComponent("x")
        do {
            try FileManager.default.createDirectory(at: ex, withIntermediateDirectories: true)
            // 下载占 0...0.9，解压/替换占 0.9...1
            try await fetcher.download(UpdateEndpoints.xrayZip(tag), to: zip) { p in progress?(p * 0.9) }
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", "-q", zip.path, "-d", ex.path]
            unzip.standardOutput = FileHandle.nullDevice
            unzip.standardError = FileHandle.nullDevice
            try unzip.run(); unzip.waitUntilExit()
            guard unzip.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: ex.appendingPathComponent("xray").path)
            else { return .failure(.applyFailed("解压失败")) }
            let dst = paths.proxyDirectory.appendingPathComponent("xray")
            if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
            try FileManager.default.copyItem(at: ex.appendingPathComponent("xray"), to: dst)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
            // 重签：arm64 无有效签名的二进制 exec 即 SIGKILL（#36）
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", dst.path]
            sign.standardOutput = FileHandle.nullDevice; sign.standardError = FileHandle.nullDevice
            try? sign.run(); sign.waitUntilExit()
            try tag.write(to: paths.proxyDirectory.appendingPathComponent(XrayBootstrap.coreStampName), atomically: true, encoding: .utf8)
            progress?(1)
            return .success(())
        } catch {
            return .failure(.applyFailed(String(describing: error)))
        }
    }
}
