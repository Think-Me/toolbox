import Foundation

/// 把内置的 xray 内核 + geoip.dat + geosite.dat 从 .app bundle 拷到可写工作目录。
///
/// 为什么不直接从 bundle 里跑：xray 在 **config.json 同目录**找 geoip.dat
/// （spec §1.1 #35），而 config.json 是运行时生成、必须落在可写目录；且 .app
/// bundle 应当只读。所以首启把三件套拷进 `AppSupport/Proxy/`，config 也生成在那儿。
public enum XrayBootstrap {
    public static let assetFiles = ["xray", "geoip.dat", "geosite.dat"]
    static let stampName = ".xray-version"
    static let bundledVersionName = "version.txt"

    public enum BootstrapError: Swift.Error, Equatable {
        case noBundledAssets       // 构建时没跑 fetch-xray.sh
        case copyFailed(String)
    }

    /// 要不要（重新）拷贝。纯函数，单独测。
    /// - 没有内置版本 → 不拷（压根没资源）
    /// - 工作目录三件套不全 → 拷
    /// - 版本戳和内置不一致（App 升级换了内核）→ 重拷
    public static func shouldCopy(bundledVersion: String?,
                                  onDiskVersion: String?,
                                  filesPresent: Bool) -> Bool {
        guard bundledVersion != nil else { return false }
        if !filesPresent { return true }
        return bundledVersion != onDiskVersion
    }

    /// 幂等地确保工作目录里有可用的内核，返回 xray 可执行文件 URL。
    @discardableResult
    public static func ensure(bundledDir: URL, workDir: URL,
                              fm: FileManager = .default) -> Result<URL, BootstrapError> {
        let bundledVersion = trimmed(read(bundledDir.appendingPathComponent(bundledVersionName), fm))
        guard let version = bundledVersion, !version.isEmpty else {
            return .failure(.noBundledAssets)
        }
        let xrayURL = workDir.appendingPathComponent("xray")
        let stampURL = workDir.appendingPathComponent(stampName)
        let onDiskVersion = trimmed(read(stampURL, fm))
        let filesPresent = assetFiles.allSatisfy {
            fm.fileExists(atPath: workDir.appendingPathComponent($0).path)
        }
        guard shouldCopy(bundledVersion: version, onDiskVersion: onDiskVersion,
                         filesPresent: filesPresent) else {
            return .success(xrayURL)
        }
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            for name in assetFiles {
                let dst = workDir.appendingPathComponent(name)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: bundledDir.appendingPathComponent(name), to: dst)
            }
            // 拷贝可能丢掉可执行位，显式补回（否则 arm64 exec 失败）
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xrayURL.path)
            try version.write(to: stampURL, atomically: true, encoding: .utf8)
            return .success(xrayURL)
        } catch {
            return .failure(.copyFailed(String(describing: error)))
        }
    }

    /// 从主 bundle 的 Resources/proxy 装到 AppPaths 的 Proxy 目录。
    public static func ensureInstalled(paths: AppPaths = .standard()) -> Result<URL, BootstrapError> {
        guard let res = Bundle.main.resourceURL else { return .failure(.noBundledAssets) }
        return ensure(bundledDir: res.appendingPathComponent("proxy", isDirectory: true),
                      workDir: paths.proxyDirectory)
    }

    private static func read(_ url: URL, _ fm: FileManager) -> String? {
        guard let data = fm.contents(atPath: url.path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    private static func trimmed(_ s: String?) -> String? {
        s?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
