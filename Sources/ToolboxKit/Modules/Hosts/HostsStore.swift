import Foundation

/// 规则库读写。存在自家 Application Support 目录，所以可以用 `.atomic`
/// （spec §4.3 禁止原子写只针对 /etc/hosts）。
public struct HostsStore: Sendable {
    public let file: URL

    public init(file: URL) { self.file = file }

    public func load() throws -> HostsLibrary {
        guard FileManager.default.fileExists(atPath: file.path) else { return .starter }
        let data = try Data(contentsOf: file)
        do {
            return try JSONDecoder().decode(HostsLibrary.self, from: data)
        } catch {
            // 与 SettingsStore 同一套策略：隔离副本 + 回落，绝不因为规则库坏了就打不开设置
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.copyItem(at: file,
                                              to: file.appendingPathExtension("corrupt-\(stamp)"))
            return .starter
        }
    }

    public func save(_ library: HostsLibrary) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(library).write(to: file, options: .atomic)
    }

    /// 翻一条规则的勾选态并落盘。
    public func toggle(ruleID: UUID, in library: inout HostsLibrary) throws {
        var flipped = false
        for gi in library.groups.indices {
            for ri in library.groups[gi].rules.indices where library.groups[gi].rules[ri].id == ruleID {
                library.groups[gi].rules[ri].enabled.toggle()
                flipped = true
                break
            }
        }
        guard flipped else { return }
        try save(library)
    }
}
