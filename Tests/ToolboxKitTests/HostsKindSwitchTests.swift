import Foundation
import Testing
@testable import ToolboxKit

@MainActor @Test func inlineToRemoteAndBackKeepsTheRule() throws {
    let dir = URL(fileURLWithPath: "/tmp/toolbox-kind-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = HostsStore(file: dir.appendingPathComponent("rules.json"))
    let rule = Rule(name: "内网", enabled: true, kind: .inline(content: "10.0.0.1 a.local\n"))
    var lib = HostsLibrary(groups: [RuleGroup(id: rule.groupProbeID, name: "公司", rules: [rule])])
    try store.save(lib)

    // 模拟界面上的两次类型切换
    lib = try switching(lib, id: rule.id, to: .remote(url: "https://x/y.txt", cachedContent: nil))
    #expect(lib.allRules.count == 1)
    lib = try switching(lib, id: rule.id, to: .inline(content: HostsContentResolver.content(of: lib.allRules[0])))
    #expect(lib.allRules.count == 1, "切回内联后规则不能消失")
    #expect(lib.allRules[0].name == "内网")
}

@MainActor @Test func remoteWithoutCacheYieldsEmptyContentButRuleSurvives() {
    let rule = Rule(name: "r", kind: .remote(url: "https://x", cachedContent: nil))
    #expect(HostsContentResolver.content(of: rule) == "")
}

private func switching(_ lib: HostsLibrary, id: UUID, to kind: RuleKind) throws -> HostsLibrary {
    var l = lib
    for gi in l.groups.indices {
        for ri in l.groups[gi].rules.indices where l.groups[gi].rules[ri].id == id {
            l.groups[gi].rules[ri].kind = kind
        }
    }
    // 关键：模拟 ViewModel 里可能把空组删掉的逻辑
    l.groups.removeAll { $0.rules.isEmpty }
    return l
}

extension Rule {
    var groupProbeID: UUID { UUID() }
}
