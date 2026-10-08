import Testing
import Foundation
@testable import ToolboxKit

private func tempDBURL() -> URL {
    URL(fileURLWithPath: "/tmp/toolbox-db-\(UUID().uuidString).sqlite")
}

/// Database 是通用封装，所以它的测试用自己的最小表。
/// 之前借用了 Schema.clipboardV1，结果业务列的 NOT NULL 约束跑进来挡测试，
/// 那是耦合：wrapper 的正确性不该依赖业务表形状。clipboardV1 的形状由
/// ClipboardStoreTests（任务 5）负责。
private let probeSchema = Schema(sql: """
CREATE TABLE IF NOT EXISTS probe (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  text BLOB,
  capacity_probe INTEGER
);
""")

@Test func opensAndCreatesTable() async throws {
    let url = tempDBURL(); defer { try? FileManager.default.removeItem(at: url) }
    let db = Database(url: url)
    try await db.open(create: probeSchema)
    #expect(try await db.scalar("select count(*) from probe") == 0)
}

@Test func insertAndQueryRoundTrip() async throws {
    let url = tempDBURL(); defer { try? FileManager.default.removeItem(at: url) }
    let db = Database(url: url)
    try await db.open(create: probeSchema)
    try await db.exec("insert into probe (id, kind, text, capacity_probe) values (?, ?, ?, ?)",
                      ["uuid-1", "text", "hello", 1])
    let rows = try await db.query("select text from probe where id = ?", ["uuid-1"]) {
        try $0.string("text")
    }
    #expect(rows == ["hello"])
}

@Test func parametersAreBoundNotConcatenated() async throws {
    let url = tempDBURL(); defer { try? FileManager.default.removeItem(at: url) }
    let db = Database(url: url)
    try await db.open(create: probeSchema)
    let evil = "'); drop table probe; --"
    try await db.exec("insert into probe (id, kind, text, capacity_probe) values (?, ?, ?, ?)",
                      ["a", "text", .text(evil), 1])
    // 表若被注入掉，这条查询会直接抛错而不是返回 1
    #expect(try await db.scalar("select count(*) from probe") == 1)
    #expect(try await db.query("select text from probe where id = ?", ["a"]) {
        try $0.string("text")
    } == [evil])
}

@Test func missingColumnSurfacesError() async throws {
    let url = tempDBURL(); defer { try? FileManager.default.removeItem(at: url) }
    let db = Database(url: url)
    try await db.open(create: probeSchema)
    await #expect(throws: DatabaseError.self) {
        _ = try await db.query("select no_such_column from probe", []) { _ in () }
    }
}

@Test func reopeningKeepsData() async throws {
    let url = tempDBURL(); defer { try? FileManager.default.removeItem(at: url) }
    let first = Database(url: url)
    try await first.open(create: probeSchema)
    try await first.exec("insert into probe (id, kind, capacity_probe) values (?, ?, ?)",
                         ["keep", "text", 1])
    let second = Database(url: url)
    try await second.open(create: probeSchema)
    #expect(try await second.scalar("select count(*) from probe") == 1)
}

@Test func nullColumnReadsAsNilNotCrash() async throws {
    let url = tempDBURL(); defer { try? FileManager.default.removeItem(at: url) }
    let db = Database(url: url)
    try await db.open(create: probeSchema)
    try await db.exec("insert into probe (id, kind, capacity_probe) values (?, ?, ?)",
                      ["n", "text", 1])
    let texts = try await db.query("select text from probe where id = ?", ["n"]) {
        try $0.optionalString("text")
    }
    #expect(texts == [nil])
}

@Test func blobRoundTripsByteForByte() async throws {
    let url = tempDBURL(); defer { try? FileManager.default.removeItem(at: url) }
    let db = Database(url: url)
    try await db.open(create: probeSchema)
    // 全 256 字节值，抓任何用 C 字符串语义处理 blob 的毛病（0x00 会截断）
    let payload = Data((0...255).map { UInt8($0) })
    try await db.exec("insert into probe (id, kind, capacity_probe, text) values (?, ?, ?, ?)",
                      ["blob", "image", 1, .blob(payload)])
    let back = try await db.query("select text from probe where id = ?", ["blob"]) {
        try $0.optionalData("text")
    }
    #expect(back == [payload])
}

@Test func scalarReadsAnonymousColumnByPosition() async throws {
    let url = tempDBURL(); defer { try? FileManager.default.removeItem(at: url) }
    let db = Database(url: url)
    try await db.open(create: probeSchema)
    try await db.exec("insert into probe (id, kind, capacity_probe) values (?, ?, ?)", ["x", "t", 7])
    // `select count(*)` 的列名是 "count(*)"，scalar 必须按位置取值才不依赖列名
    #expect(try await db.scalar("select count(*) from probe") == 1)
    #expect(try await db.scalar("select capacity_probe from probe") == 7)
}

@Test func clipboardV1SchemaCreatesUsableTable() async throws {
    let url = tempDBURL(); defer { try? FileManager.default.removeItem(at: url) }
    let db = Database(url: url)
    try await db.open(create: .clipboardV1)
    let now = Date().timeIntervalSince1970
    try await db.exec("""
    insert into clipboard_items (id, kind, text, byte_length, created_at, last_copied_at)
    values (?, ?, ?, ?, ?, ?)
    """, ["i1", "text", "payload", 7, .real(now), .real(now)])
    let got = try await db.query("select id, text, copy_count, pinned from clipboard_items", []) {
        try "\($0.string("id"))/\($0.string("text"))/\($0.int("copy_count"))/\($0.bool("pinned"))"
    }
    #expect(got == ["i1/payload/1/false"])   // 默认值由表定义给出
}

@Test func splitStatementsHandlesMultiStatementSchema() {
    let parts = Database.splitStatements("create table a(x); create index i on a(x);")
    #expect(parts.count == 2)
    #expect(parts[0].hasPrefix("create table a"))
    #expect(parts.allSatisfy { !$0.isEmpty })
}
