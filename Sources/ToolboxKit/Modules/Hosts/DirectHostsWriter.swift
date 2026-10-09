import CryptoKit
import Darwin
import Foundation

public enum HostsWriterError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 权限没到位（或被系统升级重置回 root:wheel 644）
    case notProvisioned(path: String, reason: String)
    case readFailed(path: String, reason: String)
    case writeFailed(path: String, reason: String)
    /// 写完回读不一致。**不自动重试**：反复写坏一个系统文件比停下来更糟。
    case writeVerifyFailed(expected: String, actual: String)
    case originalMissing

    public var description: String {
        switch self {
        case .notProvisioned(let p, let r): return "\(p) 不可写：\(r)"
        case .readFailed(let p, let r):     return "读取 \(p) 失败：\(r)"
        case .writeFailed(let p, let r):    return "写入 \(p) 失败：\(r)"
        case .writeVerifyFailed(let e, let a):
            return "写入后校验不一致（期望 \(e.prefix(8))… 实际 \(a.prefix(8))…），已停止，可从备份还原"
        case .originalMissing:              return "没有保存过原始 hosts，无法还原"
        }
    }
}

public protocol HostsWriting: Sendable {
    func read() throws -> String
    func write(_ content: String) throws
    func restoreOriginal() throws
}

/// 直接写 /etc/hosts（依赖一次性 `chown root:admin + chmod g+w` 授权）。
public struct DirectHostsWriter: HostsWriting {
    public let path: String
    public let backupDirectory: URL
    public let originalSnapshot: URL
    public let maxBackups: Int

    public init(path: String, backupDirectory: URL, originalSnapshot: URL,
                maxBackups: Int = 50) {
        self.path = path
        self.backupDirectory = backupDirectory
        self.originalSnapshot = originalSnapshot
        self.maxBackups = maxBackups
    }

    public func read() throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw HostsWriterError.readFailed(path: path, reason: String(cString: strerror(errno)))
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 顺序不可调换，每一步都有存在的理由（spec §4.3）。
    public func write(_ content: String) throws {
        // 1. 权威权限判定：真开一次写句柄。只看 st_mode 会在"要写的那一秒"才失败。
        //    open 返回 Int32（不是可选），<0 才是失败。
        let fd = open(path, O_WRONLY)
        guard fd >= 0 else {
            let e = errno
            throw HostsWriterError.notProvisioned(
                path: path,
                reason: e == EACCES ? "需要 root:admin 且 g+w（系统升级会重置）"
                                    : String(cString: strerror(e)))
        }
        defer { close(fd) }

        let current = try read()
        try backup(current)
        try saveOriginalIfNeeded(current)

        // 2. in-place 写：ftruncate + write + fsync。
        //    绝不能用 Data.write(.atomic)：那是 temp+rename，而 /private/etc 是
        //    drwxr-xr-x root wheel，非 root 建不了临时文件 → 必然失败；
        //    即便成功，rename 出来的新文件属主也会变，一次性授权当场作废。
        let bytes = Array(content.utf8)
        guard ftruncate(fd, 0) == 0 else {
            throw HostsWriterError.writeFailed(path: path, reason: String(cString: strerror(errno)))
        }
        var written = 0
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while written < bytes.count {
                let n = Darwin.write(fd, base + written, bytes.count - written)
                if n <= 0 {
                    throw HostsWriterError.writeFailed(path: path,
                                                       reason: String(cString: strerror(errno)))
                }
                written += n
            }
        }
        fsync(fd)

        // 3. 回读校验。不一致就报错且**不重试**。
        let back = try read()
        let expected = SHA256.hex(Data(content.utf8))
        let actual = SHA256.hex(Data(back.utf8))
        if expected != actual {
            throw HostsWriterError.writeVerifyFailed(expected: expected, actual: actual)
        }
    }

    public func restoreOriginal() throws {
        guard let original = try? String(contentsOf: originalSnapshot, encoding: .utf8) else {
            throw HostsWriterError.originalMissing
        }
        try write(original)
    }

    // MARK: 备份与原始快照

    private func backup(_ current: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        // 定宽整数微秒：字典序即时间序，轮转时才能靠排序留下最新的。
        // 不用 String(format:"%.6f")：Double 的有效位不够表示 1.79e9 秒 + 6 位小数，
        // 快速连写会撞名。
        let micros = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let name = "hosts-\(micros)"
        try? current.data(using: .utf8)?.write(to: backupDirectory.appendingPathComponent(name),
                                              options: .atomic)
        // 轮转：只留最新 maxBackups 份。名字定宽，字典序即时间序。
        // 注意别写成 dropLast(count - max)：count < max 时那是 dropLast(0)，
        // 会把整个数组（含刚写的这份）全删掉 —— 这个 bug 被备份测试当场抓到。
        if let all = try? fm.contentsOfDirectory(atPath: backupDirectory.path) {
            let hosts = all.filter { $0.hasPrefix("hosts-") }.sorted()
            if hosts.count > maxBackups {
                for old in hosts.prefix(hosts.count - maxBackups) {
                    try? fm.removeItem(at: backupDirectory.appendingPathComponent(old))
                }
            }
        }
    }

    /// 首次介入时存一份原始 hosts，作为"一键还原"的依据。
    /// 已存在就绝不覆盖 —— 否则用户改两轮之后，"原始"就变成"上一轮"了。
    private func saveOriginalIfNeeded(_ current: String) throws {
        if FileManager.default.fileExists(atPath: originalSnapshot.path) { return }
        try current.data(using: .utf8)?.write(to: originalSnapshot, options: .atomic)
    }

}
