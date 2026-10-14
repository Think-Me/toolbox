import Foundation

/// 代理库：节点列表 + 当前选中节点 + 运行时设置。整体存一个 JSON。
public struct ProxyLibrary: Codable, Equatable, Sendable {
    public var nodes: [ProxyNode]
    public var activeNodeID: UUID?
    public var runtime: ProxyRuntimeSettings

    public init(nodes: [ProxyNode] = [], activeNodeID: UUID? = nil,
                runtime: ProxyRuntimeSettings = .init()) {
        self.nodes = nodes; self.activeNodeID = activeNodeID; self.runtime = runtime
    }

    /// 缺字段回落默认（同 ProxyNode 的宽松解码策略）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = (try? c.decodeIfPresent([ProxyNode].self, forKey: .nodes)) ?? nil ?? []
        activeNodeID = (try? c.decodeIfPresent(UUID.self, forKey: .activeNodeID)) ?? nil
        runtime = (try? c.decodeIfPresent(ProxyRuntimeSettings.self, forKey: .runtime)) ?? nil ?? .init()
    }
    private enum CodingKeys: String, CodingKey { case nodes, activeNodeID, runtime }

    public var activeNode: ProxyNode? {
        guard let id = activeNodeID else { return nil }
        return nodes.first { $0.id == id }
    }

    public static let empty = ProxyLibrary()
}

/// 代理库读写。仿 HostsStore：存在自家可写目录，用 .atomic 没问题。
/// 坏文件走"隔离副本 + 回落空库"，绝不因为 nodes.json 坏了而打不开设置页。
public struct ProxyStore: Sendable {
    public let file: URL

    public init(file: URL) { self.file = file }
    public init(paths: AppPaths = .standard()) { self.file = paths.proxyLibrary }

    public func load() -> ProxyLibrary {
        guard FileManager.default.fileExists(atPath: file.path) else { return .empty }
        guard let data = try? Data(contentsOf: file) else { return .empty }
        do {
            return try JSONDecoder().decode(ProxyLibrary.self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.copyItem(at: file,
                to: file.appendingPathExtension("corrupt-\(stamp)"))
            return .empty
        }
    }

    public func save(_ library: ProxyLibrary) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(library).write(to: file, options: .atomic)
    }

    // MARK: 增删改（返回新库，由调用方落盘，便于 ViewModel 统一 save）

    public static func adding(_ node: ProxyNode, to library: ProxyLibrary) -> ProxyLibrary {
        var l = library
        l.nodes.append(node)
        if l.activeNodeID == nil { l.activeNodeID = node.id }   // 第一个自动选中
        return l
    }

    public static func removing(_ id: UUID, from library: ProxyLibrary) -> ProxyLibrary {
        var l = library
        l.nodes.removeAll { $0.id == id }
        if l.activeNodeID == id { l.activeNodeID = l.nodes.first?.id }
        return l
    }

    public static func replacing(_ node: ProxyNode, in library: ProxyLibrary) -> ProxyLibrary {
        var l = library
        if let i = l.nodes.firstIndex(where: { $0.id == node.id }) { l.nodes[i] = node }
        return l
    }

    public static func settingActive(_ id: UUID?, in library: ProxyLibrary) -> ProxyLibrary {
        var l = library; l.activeNodeID = id; return l
    }
}
