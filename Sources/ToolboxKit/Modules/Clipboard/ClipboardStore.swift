import Foundation

/// 剪贴板历史的业务读写。表结构见 `Schema.clipboardV1`。
public actor ClipboardStore {
    /// 淘汰结果。行数与媒体 sha 分开报，别让调用方猜 `trim` 的返回值到底是哪个。
    public struct TrimResult: Equatable, Sendable {
        public var deletedRows: Int
        public var deletedMediaSHAs: [String]
        public static let empty = TrimResult(deletedRows: 0, deletedMediaSHAs: [])
    }

    private let db: Database
    private let media: MediaStore

    public init(db: Database, media: MediaStore) {
        self.db = db
        self.media = media
    }

    // MARK: 写

    public func insert(_ item: ClipboardItem) async throws {
        let sql = "insert or replace into clipboard_items " + ClipboardItem.insertPlaceholders
        try await db.exec(sql, item.insertArguments())
    }

    /// 重复复制同一条：只更新计数与时间。`createdAt` 故意不动，
    /// 列表里"这条最早什么时候来的"要能看出来。
    public func bump(id: UUID, at date: Date) async throws {
        try await db.exec("""
        update clipboard_items
           set copy_count = copy_count + 1, last_copied_at = ?
         where id = ?
        """, [.real(date.timeIntervalSince1970), .text(id.uuidString)])
    }

    public func setPinned(id: UUID, _ pinned: Bool) async throws {
        try await db.exec("update clipboard_items set pinned = ? where id = ?",
                    [.int(pinned ? 1 : 0), .text(id.uuidString)])
    }

    /// 删除一行，返回它引用的媒体 sha（实体同时清掉）。
    @discardableResult
    public func delete(id: UUID) async throws -> [String] {
        let shas = try await db.query(
            "select media_sha from clipboard_items where id = ?", [.text(id.uuidString)]) {
            try $0.optionalString("media_sha")
        }.compactMap { $0 }
        try await db.exec("delete from clipboard_items where id = ?", [.text(id.uuidString)])
        for sha in shas { _ = try media.delete(sha: sha) }
        return shas
    }

    @discardableResult
    public func clearAll() async throws -> [String] {
        let shas = try await allMediaSHAs()
        try await db.exec("delete from clipboard_items")
        for sha in shas { _ = try media.delete(sha: sha) }
        return shas
    }

    /// 淘汰到 capacity 以内，返回被删掉的媒体 sha（已顺手删了实体）。
    ///
    /// 规则：**只删非置顶**，按 `last_copied_at` 升序删。
    /// 置顶数本身已超过 capacity 时**一条都不删** —— 用户显式收藏的东西
    /// 不能因为一个容量数字就丢掉，宁可暂时超容量。
    @discardableResult
    public func trim(to capacity: Int) async throws -> TrimResult {
        let total = try await db.scalar("select count(*) from clipboard_items")
        guard total > capacity else { return .empty }
        let pinnedCount = try await db.scalar("select count(*) from clipboard_items where pinned = 1")
        guard capacity > pinnedCount else { return .empty }

        let excess = total - capacity
        let doomed = try await db.query("""
        select id, media_sha from clipboard_items
         where pinned = 0
         order by last_copied_at asc, rowid asc
         limit ?
        """, [.int(excess)]) {
            (try $0.string("id"), try $0.optionalString("media_sha"))
        }
        var removedSHAs: [String] = []
        for (idString, sha) in doomed {
            try await db.exec("delete from clipboard_items where id = ?", [.text(idString)])
            if let sha {
                _ = try media.delete(sha: sha)
                removedSHAs.append(sha)
            }
        }
        return TrimResult(deletedRows: doomed.count, deletedMediaSHAs: removedSHAs)
    }

    // MARK: 读

    /// 排序规则。`rowid` 决胜不是可有可无的：时间戳相同的两行（同一 tick 内连续写入、
    /// 或时钟回跳）若不带决胜，SQLite 会按插入序返回，表现为"刚复制的反而排在后面"。
    static let orderClause = "order by pinned desc, last_copied_at desc, rowid desc"

    /// 列表顺序：置顶优先，其次最近复制，最后按插入序。
    public func recent(limit: Int) async throws -> [ClipboardItem] {
        try await Self.fetch(db, """
        select * from clipboard_items
         \(Self.orderClause)
         limit ?
        """, [.int(limit)])
    }

    /// 空查询 = 不过滤（等价于 recent）。
    public func search(_ query: String, limit: Int) async throws -> [ClipboardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await recent(limit: limit) }
        return try await Self.fetch(db, """
        select * from clipboard_items
         where text like ? escape '\\'
         \(Self.orderClause)
         limit ?
        """, [.text("%" + Self.escapeLike(trimmed) + "%"), .int(limit)])
    }

    /// 不转义的话 `%` 和 `_` 会当通配符用：搜 "100%" 会命中所有 100 开头的行，
    /// 搜 "a_b" 会连 "axb" 一起命中。反斜杠必须先处理，否则会把后面两步的
    /// 转义再转义一遍。
    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }

    public func allMediaSHAs() async throws -> [String] {
        try await db.query("select media_sha from clipboard_items where media_sha is not null", []) {
            try $0.string("media_sha")
        }
    }

    public func count() async throws -> Int {
        try await db.scalar("select count(*) from clipboard_items")
    }

    public func item(id: UUID) async throws -> ClipboardItem? {
        try await Self.fetch(db, "select * from clipboard_items where id = ? limit 1",
                       [.text(id.uuidString)]).first
    }

    private static func fetch(_ db: Database, _ sql: String,
                              _ args: [DBValue]) async throws -> [ClipboardItem] {
        try await db.query(sql, args) { try ClipboardItem(row: $0) }
    }
}
