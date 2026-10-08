import Foundation
import SQLite3

public enum DatabaseError: Error, Equatable, CustomStringConvertible {
    case openFailed(Int32)
    case prepareFailed(code: Int32, message: String)
    case stepFailed(code: Int32, message: String)
    case missingColumn(String)
    case bindFailed(index: Int, code: Int32)
    case typeMismatch(column: String, wanted: String)
    case notOpen

    public var description: String {
        switch self {
        case .openFailed(let c):            return "sqlite3 打开失败 code=\(c)"
        case .prepareFailed(let c, let m):  return "prepare 失败 code=\(c): \(m)"
        case .stepFailed(let c, let m):     return "step 失败 code=\(c): \(m)"
        case .missingColumn(let n):         return "结果里没有列 \(n)"
        case .bindFailed(let i, let c):     return "第 \(i) 个参数绑定失败 code=\(c)"
        case .typeMismatch(let n, let w):   return "列 \(n) 不是 \(w)"
        case .notOpen:                      return "数据库未打开"
        }
    }
}

/// 单元数据。做成带字面量协议的枚举，调用点就能直接写
/// `["id", 1, data]` 这种混合数组，同时保留"只能走绑定、不许拼 SQL"的约束。
public enum DBValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public init(_ v: Int) { self = .integer(Int64(v)) }
    public init(_ v: Int64) { self = .integer(v) }
    public init(_ v: Bool) { self = .integer(v ? 1 : 0) }
    public init(_ v: Double) { self = .real(v) }
    public init(_ v: String) { self = .text(v) }
    public init(_ v: Data) { self = .blob(v) }
    public static let none: DBValue = .null
}

extension DBValue: ExpressibleByNilLiteral, ExpressibleByIntegerLiteral,
                   ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
                   ExpressibleByBooleanLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(integerLiteral v: Int) { self = .integer(Int64(v)) }
    public init(floatLiteral v: Double) { self = .real(v) }
    public init(stringLiteral v: String) { self = .text(v) }
    public init(booleanLiteral v: Bool) { self = .integer(v ? 1 : 0) }
}

/// 一行的值类型快照。
/// 不直接把 `sqlite3_stmt*` 交给调用方的映射闭包：actor 的方法可能在
/// 不同线程上被恢复执行，把裸指针传出 actor 边界迟早踩未定义行为。
public struct Row: Sendable, Equatable {
    public let columns: [String: DBValue]
    /// 结果集的原始列顺序。`select count(*)` 这类匿名列只能按位置取。
    public let order: [String]

    public init(_ columns: [String: DBValue], order: [String] = []) {
        self.columns = columns
        self.order = order.isEmpty ? Array(columns.keys) : order
    }

    public func value(at index: Int) -> DBValue? {
        guard index < order.count else { return nil }
        return columns[order[index]]
    }

    public func int(at index: Int) throws -> Int {
        switch value(at: index) {
        case .integer(let i): return Int(i)
        case .real(let d):    return Int(d)
        case .some(let v):
            if case .text(let s) = v { return Int(s) ?? 0 }
            throw DatabaseError.typeMismatch(column: order[index], wanted: "INTEGER")
        case nil: throw DatabaseError.missingColumn("#\(index)")
        }
    }

    private func value(_ name: String) throws -> DBValue {
        guard let v = columns[name] else { throw DatabaseError.missingColumn(name) }
        return v
    }

    public func string(_ name: String) throws -> String {
        switch try value(name) {
        case .text(let s):  return s
        case .integer(let i): return String(i)
        case .real(let d):  return String(d)
        case .blob(let b):  return String(decoding: b, as: UTF8.self)
        case .null:         throw DatabaseError.typeMismatch(column: name, wanted: "TEXT")
        }
    }

    public func optionalString(_ name: String) throws -> String? {
        if case .null = try value(name) { return nil }
        return try string(name)
    }

    public func int(_ name: String) throws -> Int {
        switch try value(name) {
        case .integer(let i): return Int(i)
        case .real(let d):    return Int(d)
        case .text(let s):    return Int(s) ?? 0
        default:              throw DatabaseError.typeMismatch(column: name, wanted: "INTEGER")
        }
    }

    public func optionalInt(_ name: String) throws -> Int? {
        if case .null = try value(name) { return nil }
        return try int(name)
    }

    public func bool(_ name: String) throws -> Bool { (try int(name)) != 0 }

    public func optionalBool(_ name: String) throws -> Bool? {
        if case .null = try value(name) { return nil }
        return try bool(name)
    }

    public func double(_ name: String) throws -> Double {
        switch try value(name) {
        case .real(let d):     return d
        case .integer(let i):  return Double(i)
        case .text(let s):     return Double(s) ?? 0
        default:               throw DatabaseError.typeMismatch(column: name, wanted: "REAL")
        }
    }

    public func optionalDouble(_ name: String) throws -> Double? {
        if case .null = try value(name) { return nil }
        return try double(name)
    }

    public func data(_ name: String) throws -> Data {
        guard case .blob(let b) = try value(name) else {
            throw DatabaseError.typeMismatch(column: name, wanted: "BLOB")
        }
        return b
    }

    public func optionalData(_ name: String) throws -> Data? {
        switch try value(name) {
        case .null: return nil
        case .blob(let b): return b
        default: throw DatabaseError.typeMismatch(column: name, wanted: "BLOB")
        }
    }
}

public struct Schema: Sendable {
    public let sql: String
    public init(sql: String) { self.sql = sql }

    /// `capacity_probe` 只服务于 DatabaseTests 的参数绑定用例；
    /// 业务读写一律走 ClipboardStore，不碰这一列。
    public static let clipboardV1 = Schema(sql: """
    CREATE TABLE IF NOT EXISTS clipboard_items (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      text TEXT,
      media_sha TEXT,
      file_urls TEXT,
      byte_length INTEGER NOT NULL DEFAULT 0,
      pixel_w INTEGER,
      pixel_h INTEGER,
      source_bundle_id TEXT,
      source_app_name TEXT,
      pinned INTEGER NOT NULL DEFAULT 0,
      created_at REAL NOT NULL,
      last_copied_at REAL NOT NULL,
      copy_count INTEGER NOT NULL DEFAULT 1,
      capacity_probe INTEGER NOT NULL DEFAULT 1
    );
    CREATE INDEX IF NOT EXISTS idx_clip_last ON clipboard_items(last_copied_at DESC);
    CREATE INDEX IF NOT EXISTS idx_clip_pin  ON clipboard_items(pinned DESC, last_copied_at DESC);
    """)
}

/// SQLite 薄封装。单 actor 串行化所有访问，不开连接池。
public actor Database {
    private let url: URL
    private var handle: OpaquePointer?

    public init(url: URL) { self.url = url }

    public func open(create schema: Schema? = nil) throws {
        guard handle == nil else { return }
        var db: OpaquePointer?
        // FULLMUTEX 是必须的：actor 的方法可能在 cooperative pool 的
        // 不同线程上恢复执行，serialized 模式下 sqlite3 才允许这么用。
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            let code = sqlite3_errcode(db)
            sqlite3_close_v2(db)
            throw DatabaseError.openFailed(code)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
        if let schema {
            for stmt in Self.splitStatements(schema.sql) {
                try stepAll(stmt, args: [])
            }
        }
    }

    public func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    public func exec(_ sql: String, _ args: [DBValue] = []) throws {
        try stepAll(sql, args: args)
    }

    /// 取第一行第一列作为 Int（count / exists 一类）。无行时返回 0。
    /// 按位置取而不是按列名：`select count(*)` 的列名是 "count(*)"，猜不得。
    public func scalar(_ sql: String, _ args: [DBValue] = []) throws -> Int {
        let rows = try query(sql, args) { try $0.int(at: 0) }
        return rows.first ?? 0
    }

    public func query<T: Sendable>(_ sql: String, _ args: [DBValue] = [],
                                   _ map: @Sendable (Row) throws -> T) throws -> [T] {
        guard let handle else { throw DatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepareFailed(code: sqlite3_errcode(handle),
                                              message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        try bind(args, into: stmt)

        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw DatabaseError.stepFailed(code: rc,
                                               message: String(cString: sqlite3_errmsg(handle)))
            }
            out.append(try map(Self.row(from: stmt)))
        }
        return out
    }

    // MARK: - 内部

    private func stepAll(_ sql: String, args: [DBValue]) throws {
        guard let handle else { throw DatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepareFailed(code: sqlite3_errcode(handle),
                                              message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        try bind(args, into: stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DatabaseError.stepFailed(code: rc, message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func bind(_ args: [DBValue], into stmt: OpaquePointer) throws {
        for (i, arg) in args.enumerated() {
            // sqlite3 参数下标从 1 开始
            let idx = Int32(i + 1)
            let rc: Int32
            switch arg {
            case .null:
                rc = sqlite3_bind_null(stmt, idx)
            case .integer(let v):
                rc = sqlite3_bind_int64(stmt, idx, v)
            case .real(let v):
                rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let s):
                // SQLITE_TRANSIENT 让 sqlite 自己拷贝，Swift 字符串缓冲区不必活过这一步
                rc = sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .blob(let d):
                rc = d.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(d.count), Self.transient)
                }
            }
            guard rc == SQLITE_OK else {
                throw DatabaseError.bindFailed(index: i, code: rc)
            }
        }
    }

    private static func row(from stmt: OpaquePointer) -> Row {
        var cols: [String: DBValue] = [:]
        var order: [String] = []
        let count = sqlite3_column_count(stmt)
        for i in 0..<count {
            let name = String(cString: sqlite3_column_name(stmt, i))
            order.append(name)
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_NULL:  cols[name] = .null
            case SQLITE_INTEGER: cols[name] = .integer(sqlite3_column_int64(stmt, i))
            case SQLITE_FLOAT: cols[name] = .real(sqlite3_column_double(stmt, i))
            case SQLITE_BLOB:
                let n = Int(sqlite3_column_bytes(stmt, i))
                if let base = sqlite3_column_blob(stmt, i), n > 0 {
                    cols[name] = .blob(Data(bytes: base, count: n))
                } else {
                    cols[name] = .blob(Data())
                }
            default:
                let n = Int(sqlite3_column_bytes(stmt, i))
                if let base = sqlite3_column_text(stmt, i) {
                    cols[name] = .text(String(decoding: Data(bytes: base, count: n).prefix(n), as: UTF8.self))
                } else {
                    cols[name] = .text("")
                }
            }
        }
        return Row(cols, order: order)
    }

    /// schema 里多条语句要拆开逐条 prepare（sqlite3_prepare_v2 一次只编一条）。
    static func splitStatements(_ sql: String) -> [String] {
        sql.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// `SQLITE_TRANSIENT` 在 Swift 里没被导入成可用符号，手工构造。
    static let transient: sqlite3_destructor_type = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
