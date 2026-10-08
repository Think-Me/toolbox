import Foundation

public enum ClipboardKind: String, Codable, Sendable, Equatable {
    case text
    case image
    case fileURLs
}

public enum ClipboardItemError: Error, Equatable {
    case unknownKind(String)
    case missingField(String)
}

/// 一条剪贴板历史。图片的字节**不存 DB**，只存 sha256，实体在 MediaStore。
/// 4K 截图 PNG 有 5–10MB，500 条会把库撑到几百 MB 并拖慢一切查询。
public struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    /// 文件路径的连接符。必须用 U+2028：文件名里换行是合法的，
    /// 用 "\n" 连接会把一条路径切成两条（有测试锁住）。
    public static let urlSeparator = "\u{2028}"

    public let id: UUID
    public var kind: ClipboardKind
    public var text: String?
    public var mediaSHA256: String?
    public var fileURLs: [URL]?
    public var byteLength: Int
    public var pixelSize: CGSize?
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var pinned: Bool
    public var createdAt: Date
    public var lastCopiedAt: Date
    public var copyCount: Int

    public init(id: UUID = UUID(), kind: ClipboardKind, text: String?,
                mediaSHA256: String?, fileURLs: [URL]?, byteLength: Int,
                pixelSize: CGSize?, sourceBundleID: String?, sourceAppName: String?,
                pinned: Bool = false, createdAt: Date, lastCopiedAt: Date,
                copyCount: Int = 1) {
        self.id = id; self.kind = kind; self.text = text
        self.mediaSHA256 = mediaSHA256; self.fileURLs = fileURLs
        self.byteLength = byteLength; self.pixelSize = pixelSize
        self.sourceBundleID = sourceBundleID; self.sourceAppName = sourceAppName
        self.pinned = pinned; self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt; self.copyCount = copyCount
    }

    // MARK: 便捷构造（采集侧用）

    public init(text: String, sourceBundleID: String?, sourceAppName: String?, at date: Date) {
        self.init(kind: .text, text: text, mediaSHA256: nil, fileURLs: nil,
                  byteLength: text.utf8.count, pixelSize: nil,
                  sourceBundleID: sourceBundleID, sourceAppName: sourceAppName,
                  createdAt: date, lastCopiedAt: date)
    }

    public init(fileURLs urls: [URL], sourceBundleID: String?, sourceAppName: String?, at date: Date) {
        // 搜索用的文本：把换行折成空格，保证列表一行只显示一条
        let joined = urls.map { $0.path.replacingOccurrences(of: "\n", with: " ") }
                         .joined(separator: "  ")
        self.init(kind: .fileURLs, text: joined, mediaSHA256: nil, fileURLs: urls,
                  byteLength: joined.utf8.count, pixelSize: nil,
                  sourceBundleID: sourceBundleID, sourceAppName: sourceAppName,
                  createdAt: date, lastCopiedAt: date)
    }

    public init(imagePNG png: Data, sha256: String, pixelSize: CGSize?,
                sourceBundleID: String?, sourceAppName: String?, at date: Date) {
        self.init(kind: .image, text: nil, mediaSHA256: sha256, fileURLs: nil,
                  byteLength: png.count, pixelSize: pixelSize,
                  sourceBundleID: sourceBundleID, sourceAppName: sourceAppName,
                  createdAt: date, lastCopiedAt: date)
    }

    // MARK: 展示

    /// 列表里显示的单行摘要。
    public var displayPreview: String {
        switch kind {
        case .text:
            let folded = (text ?? "").replacingOccurrences(of: "\n", with: " ")
                                     .replacingOccurrences(of: "\t", with: " ")
            guard !folded.isEmpty else { return "" }
            if folded.count <= 120 { return folded }
            return String(folded.prefix(119)) + "…"
        case .image:
            let size = pixelSize.map { " \((Int($0.width)))×\((Int($0.height)))" } ?? ""
            return "图片\(size)"
        case .fileURLs:
            let n = fileURLs?.count ?? 0
            let first = fileURLs?.first?.lastPathComponent ?? ""
            return n <= 1 ? "文件 \(first)" : "文件 ×\(n) \(first)"
        }
    }

    // MARK: DB 映射

    public static let insertColumns: [String] = [
        "id", "kind", "text", "media_sha", "file_urls", "byte_length",
        "pixel_w", "pixel_h", "source_bundle_id", "source_app_name",
        "pinned", "created_at", "last_copied_at", "copy_count",
    ]

    public static let insertPlaceholders: String =
        "(\(Self.insertColumns.joined(separator: ", "))) values (\(Array(repeating: "?", count: Self.insertColumns.count).joined(separator: ", ")))"

    public func insertArguments() -> [DBValue] {
        [
            .text(id.uuidString),
            .text(kind.rawValue),
            text.map { .text($0) } ?? .null,
            mediaSHA256.map { .text($0) } ?? .null,
            fileURLs.map { .text($0.map(\.path).joined(separator: Self.urlSeparator)) } ?? .null,
            .integer(Int64(byteLength)),
            pixelSize.map { .integer(Int64($0.width)) } ?? .null,
            pixelSize.map { .integer(Int64($0.height)) } ?? .null,
            sourceBundleID.map { .text($0) } ?? .null,
            sourceAppName.map { .text($0) } ?? .null,
            .integer(pinned ? 1 : 0),
            .real(createdAt.timeIntervalSince1970),
            .real(lastCopiedAt.timeIntervalSince1970),
            .integer(Int64(copyCount)),
        ]
    }

    /// 测试与本地调试用的反向快照：走的是和写库完全同一份映射。
    public func asRow() -> Row {
        var cols: [String: DBValue] = [:]
        for (name, value) in zip(Self.insertColumns, insertArguments()) { cols[name] = value }
        return Row(cols)
    }

    public init(row: Row) throws {
        guard case .text(let idString)? = row.columns["id"], let uuid = UUID(uuidString: idString) else {
            throw ClipboardItemError.missingField("id")
        }
        guard case .text(let kindString)? = row.columns["kind"],
              let parsed = ClipboardKind(rawValue: kindString) else {
            // 脏数据/未来版本一律显式失败，不许悄悄当文本处理
            throw ClipboardItemError.unknownKind(
                (row.columns["kind"].flatMap { if case .text(let s) = $0 { return s } else { return nil } }) ?? "<nil>")
        }
        self.id = uuid
        self.kind = parsed
        self.text = try row.optionalString("text")
        self.mediaSHA256 = try row.optionalString("media_sha")
        if case .text(let joined)? = row.columns["file_urls"] {
            self.fileURLs = joined.components(separatedBy: Self.urlSeparator)
                .filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        } else {
            self.fileURLs = nil
        }
        self.byteLength = (try? row.int("byte_length")) ?? 0
        if let w = try row.optionalInt("pixel_w"), let h = try row.optionalInt("pixel_h") {
            self.pixelSize = CGSize(width: w, height: h)
        } else {
            self.pixelSize = nil
        }
        self.sourceBundleID = try row.optionalString("source_bundle_id")
        self.sourceAppName = try row.optionalString("source_app_name")
        self.pinned = ((try? row.int("pinned")) ?? 0) != 0
        let created = try row.optionalDouble("created_at") ?? 0
        let copied = try row.optionalDouble("last_copied_at") ?? created
        self.createdAt = Date(timeIntervalSince1970: created)
        self.lastCopiedAt = Date(timeIntervalSince1970: copied)
        self.copyCount = (try? row.int("copy_count")) ?? 1
    }
}
