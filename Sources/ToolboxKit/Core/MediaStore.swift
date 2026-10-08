import Foundation

/// 图片的实体存储：内容寻址，文件名就是 sha256。
///
/// 为什么不进 SQLite：4K 截图的 PNG 有 5–10MB，500 条会把库撑到几百 MB，
/// 每次查询和备份都跟着变慢；而且内容寻址天然去重（同一张图复制十次只占一份）。
public struct MediaStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// 写入并返回 sha。同一内容重复写只会得到一个文件。
    @discardableResult
    public func store(png: Data) throws -> String {
        let sha = SHA256.hex(png)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = fileURL(forHex: sha)
        if FileManager.default.fileExists(atPath: dest.path) { return sha }
        // 自家 Application Support 目录，.atomic（temp+rename）安全。
        // spec §4.3 禁用原子写只针对 /etc/hosts（那里目录不可写，rename 必然失败）。
        try png.write(to: dest, options: .atomic)
        return sha
    }

    public func data(sha: String) throws -> Data? {
        guard let url = fileURL(ifValidSHA: sha) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// 返回 false 表示没删任何东西（无效 sha 或文件不存在）。
    @discardableResult
    public func delete(sha: String) throws -> Bool {
        guard let url = fileURL(ifValidSHA: sha) else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.removeItem(at: url)
        return true
    }

    /// 删掉所有不被 liveSHAs 引用的图片。返回删除数量。
    /// 先算集合再删，中途崩溃只会留下孤儿文件（下次 GC 再收），不会误删有用数据。
    @discardableResult
    public func garbageCollect(liveSHAs: Set<String>) throws -> Int {
        let live = Set(liveSHAs.filter { SHA256.isPlausibleHex($0) })
        let onDisk = try allSHAs()
        var removed = 0
        for sha in onDisk where !live.contains(sha) {
            if (try? delete(sha: sha)) ?? false { removed += 1 }
        }
        return removed
    }

    public func allSHAs() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names.compactMap { name in
            guard name.hasSuffix(".png") else { return nil }
            let hex = String(name.dropLast(4))
            return SHA256.isPlausibleHex(hex) ? hex : nil
        }.sorted()
    }

    public func totalBytes() throws -> Int {
        var total = 0
        for sha in try allSHAs() {
            guard let url = fileURL(ifValidSHA: sha) else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            total += (attrs?[.size] as? Int) ?? 0
        }
        return total
    }

    // MARK: - 路径安全

    /// sha 来自 DB 行，可能被手工编辑过。非纯小写 hex 一律拒绝，
    /// 否则 `../../etc/hosts` 会变成一次任意路径写/删。
    private func fileURL(ifValidSHA sha: String) -> URL? {
        guard SHA256.isPlausibleHex(sha) else { return nil }
        return fileURL(forHex: sha)
    }

    private func fileURL(forHex sha: String) -> URL {
        directory.appendingPathComponent("\(sha).png")
    }
}
