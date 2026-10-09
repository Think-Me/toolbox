import AppKit
import Foundation
import SwiftUI

/// Hosts 模块的界面状态。设置页与 `⌘⇧H` 浮层共用同一份，
/// 否则两边会显示不同的勾选态（经典的双份状态 bug）。
@MainActor
public final class HostsViewModel: ObservableObject {
    @Published public var library: HostsLibrary
    @Published public var selectedRuleID: UUID?
    @Published public var statusMessage: String?
    @Published public var busy = false

    public let store: HostsStore
    private let applying: HostsApplying
    private let sync: RemoteSync

    public init(store: HostsStore, applying: HostsApplying, sync: RemoteSync = RemoteSync()) {
        self.store = store
        self.applying = applying
        self.sync = sync
        self.library = (try? store.load()) ?? .starter
        // 默认选中第一条：否则打开这一页右半边是空的，看起来像没加载出来
        self.selectedRuleID = library.allRules.first?.id
    }

    /// 拉取所有到期的远程规则。失败保留旧缓存，绝不让规则凭空消失。
    public func syncAllRemotes(force: Bool = false) async {
        busy = true
        defer { busy = false }
        var updated = 0
        var failed: [String] = []
        for gi in library.groups.indices {
            for ri in library.groups[gi].rules.indices {
                guard case .remote(let url, let cached) = library.groups[gi].rules[ri].kind else { continue }
                let rule = library.groups[gi].rules[ri]
                if !force, let interval = rule.syncInterval,
                   let last = rule.lastSyncAt,
                   Date().timeIntervalSince(last) < interval { continue }
                let outcome = await sync.sync(url: url, etag: rule.etag, cached: cached)
                switch outcome {
                case .updated(let content, let etag):
                    library.groups[gi].rules[ri].kind = .remote(url: url, cachedContent: content)
                    library.groups[gi].rules[ri].etag = etag
                    library.groups[gi].rules[ri].lastSyncAt = Date()
                    library.groups[gi].rules[ri].lastError = nil
                    updated += 1
                case .notModified:
                    library.groups[gi].rules[ri].lastSyncAt = Date()
                case .usedCache(_, let reason):
                    library.groups[gi].rules[ri].lastError = "用缓存：\(reason)"
                    failed.append(rule.name)
                case .failed(let reason):
                    library.groups[gi].rules[ri].lastError = "\(reason)"
                    failed.append(rule.name)
                }
            }
        }
        try? store.save(library)
        statusMessage = failed.isEmpty
            ? (updated > 0 ? "已同步 \(updated) 条远程规则" : "远程规则均无更新")
            : "\(updated) 条已更新，\(failed.count) 条失败（沿用上次缓存）"
        if updated > 0 { await apply(library) }
    }

    public var selectedRule: Rule? {
        guard let id = selectedRuleID else { return nil }
        return library.allRules.first { $0.id == id }
    }

    public var conflicts: [DomainConflict] {
        RuleCompiler.conflicts(library.enabledRules.map {
            NamedRule(name: $0.name, content: HostsContentResolver.content(of: $0))
        })
    }

    /// 必须 @Published：不发布的话 SwiftUI 不会重算，"保存并应用"按钮永远灰着。
    @Published public var hasUnsavedContent: Bool = false

    // MARK: 操作

    /// 切换一条规则并立即应用。
    public func toggle(_ id: UUID) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var lib = library
        do {
            try store.toggle(ruleID: id, in: &lib)
        } catch {
            statusMessage = "保存规则库失败：\(error)"
            return
        }
        library = lib
        await apply(lib)
    }

    public func setManagementOn(_ on: Bool) async {
        busy = true
        defer { busy = false }
        var lib = library
        lib.managementOn = on
        do { try store.save(lib) } catch {
            statusMessage = "保存失败：\(error)"; return
        }
        library = lib
        await apply(lib)
    }

    public func updateContent(_ text: String) {
        guard let id = selectedRuleID else { return }
        for gi in library.groups.indices {
            for ri in library.groups[gi].rules.indices where library.groups[gi].rules[ri].id == id {
                guard library.groups[gi].rules[ri].kind.isInline else { return }
                library.groups[gi].rules[ri].kind = .inline(content: text)
                hasUnsavedContent = true
            }
        }
    }

    public func commitContent() async {
        guard hasUnsavedContent else { return }
        busy = true
        defer { busy = false }
        do { try store.save(library) } catch {
            statusMessage = "保存失败：\(error)"; return
        }
        hasUnsavedContent = false
        await apply(library)
    }

    public func addRule(to groupID: UUID? = nil) {
        let rule = Rule(name: "新规则 \(library.allRules.count + 1)",
                        kind: .inline(content: "127.0.0.1 example.com\n"))
        if let groupID, let gi = library.groups.firstIndex(where: { $0.id == groupID }) {
            library.groups[gi].rules.append(rule)
        } else {
            library.groups.append(RuleGroup(name: "新分组", rules: [rule]))
        }
        selectedRuleID = rule.id
        Task { try? store.save(library) }
    }

    public func delete(_ id: UUID) async {
        for gi in library.groups.indices {
            library.groups[gi].rules.removeAll { $0.id == id }
        }
        library.groups.removeAll { $0.rules.isEmpty }
        if selectedRuleID == id { selectedRuleID = library.allRules.first?.id }
        busy = true
        defer { busy = false }
        try? store.save(library)
        await apply(library)
    }

    public enum KindTag: Hashable { case inline, remote }

    /// 切换规则类型。**必须把当前文本带进新 kind**：
    /// 之前切到远程时传 `cachedContent: nil`，于是 内联→远程→内联 会把内容清空，
    /// 用户看到的就是"规则消失了"。
    public func switchKind(_ id: UUID, to tag: KindTag) {
        guard let rule = library.allRules.first(where: { $0.id == id }) else { return }
        let current = HostsContentResolver.content(of: rule)
        let kind: RuleKind
        switch tag {
        case .inline:
            // 从远程切回来：优先用已同步下来的缓存内容，它比旧的内联文本新
            if case .remote(_, let cached) = rule.kind, let cached, !cached.isEmpty {
                kind = .inline(content: cached)
            } else {
                kind = .inline(content: current)
            }
        case .remote:
            let existingURL: String
            if case .remote(let u, _) = rule.kind { existingURL = u } else { existingURL = "" }
            kind = .remote(url: existingURL, cachedContent: current)
        }
        setKind(id, kind: kind)
    }

    /// 改规则类型：内联 / 远程。远程规则必须能在这里填地址，
    /// 否则"同步远程"按钮就是个没有入口的死功能。
    public func setKind(_ id: UUID, kind: RuleKind) {
        for gi in library.groups.indices {
            for ri in library.groups[gi].rules.indices where library.groups[gi].rules[ri].id == id {
                library.groups[gi].rules[ri].kind = kind
                library.groups[gi].rules[ri].lastError = nil
            }
        }
        Task {
            try? store.save(library)
            await apply(library)
        }
    }

    public func setSyncInterval(_ id: UUID, seconds: TimeInterval?) {
        for gi in library.groups.indices {
            for ri in library.groups[gi].rules.indices where library.groups[gi].rules[ri].id == id {
                library.groups[gi].rules[ri].syncInterval = seconds
            }
        }
        Task { try? store.save(library) }
    }

    /// 手动同步单条远程规则
    public func syncOne(_ id: UUID) async {
        guard let rule = library.allRules.first(where: { $0.id == id }),
              case .remote(let url, let cached) = rule.kind else { return }
        busy = true
        defer { busy = false }
        let outcome = await sync.sync(url: url, etag: rule.etag, cached: cached)
        for gi in library.groups.indices {
            for ri in library.groups[gi].rules.indices where library.groups[gi].rules[ri].id == id {
                switch outcome {
                case .updated(let content, let etag):
                    library.groups[gi].rules[ri].kind = .remote(url: url, cachedContent: content)
                    library.groups[gi].rules[ri].etag = etag
                    library.groups[gi].rules[ri].lastSyncAt = Date()
                    library.groups[gi].rules[ri].lastError = nil
                    statusMessage = "已同步「\(rule.name)」\(content.utf8.count) 字节"
                case .notModified:
                    library.groups[gi].rules[ri].lastSyncAt = Date()
                    statusMessage = "「\(rule.name)」无更新（304）"
                case .usedCache(_, let reason):
                    statusMessage = "「\(rule.name)」拉取失败，沿用缓存：\(reason)"
                case .failed(let reason):
                    statusMessage = "「\(rule.name)」同步失败：\(reason)"
                }
            }
        }
        try? store.save(library)
        await apply(library)
    }

    public func rename(_ id: UUID, to name: String) {
        for gi in library.groups.indices {
            for ri in library.groups[gi].rules.indices where library.groups[gi].rules[ri].id == id {
                library.groups[gi].rules[ri].name = name
            }
        }
        Task { try? store.save(library) }
    }

    public func restoreOriginal() async {
        busy = true
        defer { busy = false }
        guard let outcome = try? await applying.restoreOriginal() else {
            statusMessage = "还原失败：无法访问 hosts"
            return
        }
        switch outcome {
        case .success:
            statusMessage = "已还原为原始 hosts"
        case .refused(let m), .failed(let m):
            statusMessage = m
        }
    }

    /// 应用当前规则库，并把结果翻译成人话。
    private func apply(_ lib: HostsLibrary) async {
        switch (try? await applying.apply(library: lib)) ?? .failed("未知错误") {
        case .success(let r):
            if r.writtenBytes == 0 {
                statusMessage = lib.managementOn ? "无变化" : "托管已关闭"
            } else {
                switch r.dns {
                case .ok:
                    statusMessage = "已应用（\(r.writtenBytes) 字节）"
                case .needsProvisioned(let m), .failed(let m):
                    // 写成功了但没刷成缓存：必须说清楚，否则用户会以为切换没生效
                    statusMessage = "已写入，但 DNS 缓存未刷新：\(m)"
                }
                if !r.conflicts.isEmpty {
                    statusMessage = (statusMessage ?? "") + " · \(r.conflicts.count) 处域名冲突"
                }
            }
        case .refused(let m):
            statusMessage = m
        case .failed(let m):
            statusMessage = m
        }
    }
}

/// 规则内容取值。remote 用缓存，localFile 现读；读不到就当空，
/// 绝不让一条坏规则把整个面板拖崩。
enum HostsContentResolver {
    static func content(of rule: Rule) -> String {
        switch rule.kind {
        case .inline(let c): return c
        case .localFile(let p): return (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
        case .remote(_, let cached): return cached ?? ""
        }
    }

    /// 用函数而不是 `static var` 存闭包：后者是全局共享可变状态，Swift 6 直接拒绝。
    static func isEditable(_ rule: Rule) -> Bool {
        if case .inline = rule.kind { return true }
        return false
    }
}

extension RuleKind {
    var isInline: Bool { if case .inline = self { return true } else { return false } }
    var displayName: String {
        switch self {
        case .inline: return "内联"
        case .localFile: return "本地文件"
        case .remote(let url, _): return "远程 \(URL(string: url)?.host ?? url)"
        }
    }
}
