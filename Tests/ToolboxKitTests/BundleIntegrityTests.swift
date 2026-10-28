import Foundation
import Testing
@testable import ToolboxKit

@Test func staleDetectedAfterExecutableReplaced() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("toolbox-integrity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let exe = dir.appendingPathComponent("Toolbox")
    try Data("old".utf8).write(to: exe)
    let integrity = BundleIntegrity(url: exe)
    #expect(!integrity.isStale)

    // 模拟 build-app.sh：rm -rf 后重建
    try FileManager.default.removeItem(at: exe)
    try Data("new-binary".utf8).write(to: exe)
    #expect(integrity.isStale)

    // 被整体删掉（make clean）同样算失效
    try FileManager.default.removeItem(at: exe)
    #expect(integrity.isStale)
}

@Test func unreadableAtBootNeverFlagsStale() throws {
    // 判不准时宁可放行：不许误伤正常实例
    let exe = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("toolbox-integrity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: exe) }
    let integrity = BundleIntegrity(url: exe)
    try Data("x".utf8).write(to: exe)
    #expect(!integrity.isStale)
}
