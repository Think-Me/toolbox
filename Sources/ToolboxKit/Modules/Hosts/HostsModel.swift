import Foundation

/// 一条 hosts 映射（一个域名一行）。
public struct HostsMapping: Equatable, Sendable, Hashable {
    public let ip: String
    public let domain: String
    public init(ip: String, domain: String) { self.ip = ip; self.domain = domain }
}

/// 参与编译的一条规则（已经把内容解析出来了）
public struct NamedRule: Equatable, Sendable {
    public let name: String
    public let content: String
    public init(name: String, content: String) { self.name = name; self.content = content }
}

public struct DomainConflict: Equatable, Sendable {
    public struct Side: Equatable, Sendable {
        public let ruleName: String
        public let ip: String
    }
    public let domain: String
    public let mappings: [Side]
}

public struct CompileStats: Equatable, Sendable {
    public var enabledRuleCount: Int
    public var mappingCount: Int
}

public struct CompileResult: Equatable, Sendable {
    public var content: String
    public var conflicts: [DomainConflict]
    public var stats: CompileStats
}

public enum CompileError: Error, Equatable, Sendable {
    /// 哨兵标签不配对。绝不猜测托管块的范围：
    /// 猜错会把用户手写的行整段吞掉，或者留下永远清不掉的残块。
    case brokenSentinel(reason: String)
}

// MARK: 规则库

public enum RuleKind: Codable, Equatable, Sendable {
    case inline(content: String)
    case localFile(path: String)
    case remote(url: String, cachedContent: String?)
}

public struct Rule: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var enabled: Bool
    public var kind: RuleKind
    public var lastSyncAt: Date?
    public var syncInterval: TimeInterval?
    public var etag: String?
    public var lastError: String?

    public init(id: UUID = UUID(), name: String, enabled: Bool = false, kind: RuleKind,
                lastSyncAt: Date? = nil, syncInterval: TimeInterval? = nil,
                etag: String? = nil, lastError: String? = nil) {
        self.id = id; self.name = name; self.enabled = enabled; self.kind = kind
        self.lastSyncAt = lastSyncAt; self.syncInterval = syncInterval
        self.etag = etag; self.lastError = lastError
    }
}

public struct RuleGroup: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var collapsed: Bool
    public var rules: [Rule]

    public init(id: UUID = UUID(), name: String, collapsed: Bool = false, rules: [Rule] = []) {
        self.id = id; self.name = name; self.collapsed = collapsed; self.rules = rules
    }
}

public struct HostsLibrary: Codable, Equatable, Sendable {
    public var version: Int
    /// 总开关。关掉 = 把托管块整个摘掉并还原原始 hosts。
    public var managementOn: Bool
    public var groups: [RuleGroup]

    public init(version: Int = 1, managementOn: Bool = true, groups: [RuleGroup] = []) {
        self.version = version; self.managementOn = managementOn; self.groups = groups
    }

    public var allRules: [Rule] { groups.flatMap(\.rules) }
    public var enabledRules: [Rule] { allRules.filter(\.enabled) }

    /// 内置一份示例规则：第一次打开设置页时界面不会是空的，
    /// 用户能立刻看懂"组 → 规则 → 勾选"这个层级。
    public static let starter = HostsLibrary(groups: [
        RuleGroup(name: "示例", rules: [
            Rule(name: "本地开发", enabled: false,
                 kind: .inline(content: "127.0.0.1 dev.example.com\n")),
        ]),
    ])
}
