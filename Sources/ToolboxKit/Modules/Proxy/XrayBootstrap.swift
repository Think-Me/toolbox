import Foundation

/// 把内置的 xray 内核 + geoip.dat + geosite.dat 从 .app bundle 拷到可写工作目录。
///
/// 为什么不直接从 bundle 里跑：xray 在 **config.json 同目录**找 geoip.dat
/// （spec §1.1 #35），而 config.json 是运行时生成、必须落在可写目录；且 .app
/// bundle 应当只读。所以首启把三件套拷进 `AppSupport/Proxy/`，config 也生成在那儿。
///
/// 更新策略（配合 UpdateService）：
/// - 内核：仅当缺失、或**内置版本比已装版本新**时才覆盖（semver 比较）。
///   这样运行时更新到更新的内核后，App 重启不会把它冲回旧版。
/// - 规则库 dat：仅当缺失时播种。之后由 UpdateService 独立更新，不受 App 版本影响。
public enum XrayBootstrap {
    public static let coreFiles = ["xray"]
    public static let ruleFiles = ["geoip.dat", "geosite.dat"]
    public static let coreStampName = ".xray-version"
    public static let bundledVersionName = "version.txt"

    public enum BootstrapError: Swift.Error, Equatable {
        case noBundledAssets
        case copyFailed(String)
    }

    /// 内核要不要覆盖：缺失，或内置比已装新。
    public static func shouldCopyCore(bundledVersion: String?, onDiskVersion: String?,
                                      present: Bool) -> Bool {
        guard bundledVersion != nil else { return false }
        if !present { return true }
        return ProxyVersion.isNewer(bundledVersion, than: onDiskVersion)
    }

    /// 规则库要不要播种：只在缺失时（更新交给 UpdateService）。
    public static func shouldSeedRules(present: Bool) -> Bool { !present }

    @discardableResult
    public static func ensure(bundledDir: URL, workDir: URL,
                              fm: FileManager = .default) -> Result<URL, BootstrapError> {
        let bundledVersion = trimmed(read(bundledDir.appendingPathComponent(bundledVersionName), fm))
        guard let version = bundledVersion, !version.isEmpty else {
            return .failure(.noBundledAssets)
        }
        let xrayURL = workDir.appendingPathComponent("xray")
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            let corePresent = fm.fileExists(atPath: xrayURL.path)
            let onDiskVersion = trimmed(read(workDir.appendingPathComponent(coreStampName), fm))
            if shouldCopyCore(bundledVersion: version, onDiskVersion: onDiskVersion, present: corePresent) {
                if fm.fileExists(atPath: xrayURL.path) { try fm.removeItem(at: xrayURL) }
                try fm.copyItem(at: bundledDir.appendingPathComponent("xray"), to: xrayURL)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xrayURL.path)
                try version.write(to: workDir.appendingPathComponent(coreStampName), atomically: true, encoding: .utf8)
            }
            let rulesPresent = ruleFiles.allSatisfy {
                fm.fileExists(atPath: workDir.appendingPathComponent($0).path)
            }
            if shouldSeedRules(present: rulesPresent) {
                for name in ruleFiles {
                    let dst = workDir.appendingPathComponent(name)
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    try fm.copyItem(at: bundledDir.appendingPathComponent(name), to: dst)
                }
            }
            return .success(xrayURL)
        } catch {
            return .failure(.copyFailed(String(describing: error)))
        }
    }

    public static func ensureInstalled(paths: AppPaths = .standard()) -> Result<URL, BootstrapError> {
        guard let res = Bundle.main.resourceURL else { return .failure(.noBundledAssets) }
        return ensure(bundledDir: res.appendingPathComponent("proxy", isDirectory: true),
                      workDir: paths.proxyDirectory)
    }

    private static func read(_ url: URL, _ fm: FileManager) -> String? {
        guard let data = fm.contents(atPath: url.path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    private static func trimmed(_ s: String?) -> String? { s?.trimmingCharacters(in: .whitespacesAndNewlines) }
}
