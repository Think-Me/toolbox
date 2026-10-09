import Foundation
import Testing
@testable import ToolboxKit

// MARK: 解析

@Test func parsesSimpleMappings() {
    let m = RuleCompiler.parseMappings("127.0.0.1 localhost\n::1 localhost\n")
    #expect(m.count == 2)
    #expect(m[0] == HostsMapping(ip: "127.0.0.1", domain: "localhost"))
    #expect(m[1] == HostsMapping(ip: "::1", domain: "localhost"))
}

@Test func oneLineManyDomainsYieldsOneMappingEach() {
    let m = RuleCompiler.parseMappings("10.0.0.1 a.com b.com c.com")
    #expect(m.map(\.domain) == ["a.com", "b.com", "c.com"])
    #expect(Set(m.map(\.ip)) == ["10.0.0.1"])
}

@Test func ignoresCommentsBlankLinesAndTrailingSpace() {
    let src = """
    # 注释行
    // 另一种注释

       \t
    127.0.0.1   example.com   \t \n
    notanip line
    127.0.0.1
    """
    let m = RuleCompiler.parseMappings(src)
    #expect(m == [HostsMapping(ip: "127.0.0.1", domain: "example.com")])
}

@Test func toleratesCRLFAndInlineComment() {
    let m = RuleCompiler.parseMappings("127.0.0.1 a.com # 我的标记\r\n127.0.0.2 b.com//c\r\n")
    #expect(m == [HostsMapping(ip: "127.0.0.1", domain: "a.com"),
                  HostsMapping(ip: "127.0.0.2", domain: "b.com")])
}

// MARK: 冲突检测

@Test func detectsSameDomainDifferentIP() {
    let rules = [NamedRule(name: "开发", content: "10.1.1.1 api.example.com"),
                 NamedRule(name: "测试", content: "10.2.2.2 api.example.com")]
    let c = RuleCompiler.conflicts(rules)
    #expect(c.count == 1)
    #expect(c[0].domain == "api.example.com")
    #expect(c[0].mappings.map(\.ruleName) == ["开发", "测试"])
}

@Test func sameDomainSameIPIsNotAConflict() {
    let rules = [NamedRule(name: "a", content: "10.1.1.1 x.com"),
                 NamedRule(name: "b", content: "10.1.1.1 x.com")]
    #expect(RuleCompiler.conflicts(rules).isEmpty)
}

@Test func conflictOrderFollowsRuleOrder() {
    let rules = [NamedRule(name: "z", content: "1.1.1.1 d.com"),
                 NamedRule(name: "y", content: "2.2.2.2 d.com"),
                 NamedRule(name: "x", content: "3.3.3.3 d.com")]
    #expect(RuleCompiler.conflicts(rules).first?.mappings.map(\.ruleName) == ["z", "y", "x"])
}

// MARK: 编译：哨兵块模型

private let baseHosts = """
##
# 系统基础
##
127.0.0.1 localhost
255.255.255.255 broadcasthost
::1 localhost
"""

@Test func emptyRulesetKeepsHostsUnchanged() throws {
    let r = try #require(try? RuleCompiler.compile(enabled: [], currentHosts: baseHosts).get())
    // 多行字符串字面量结尾**不带**换行，而实现保证 hosts 以恰好一个换行结尾
    // （hosts 文件必须如此），所以这里比的是 baseHosts + "\n"。
    #expect(r.content == baseHosts + "\n")
    #expect(r.content.contains(RuleCompiler.beginSentinel) == false)
}

@Test func writesManagedBlockAndPreservesUserLines() throws {
    let userLine = "8.8.8.8 my-own-host.local"
    let current = baseHosts + "\n" + userLine + "\n"
    let r = try #require(try? RuleCompiler.compile(
        enabled: [NamedRule(name: "本地开发", content: "127.0.0.1 dev.example.com")],
        currentHosts: current).get())
    // 用户手写的行必须原样保留（我们不接管块外的内容）
    #expect(r.content.contains(userLine))
    #expect(r.content.contains("127.0.0.1 dev.example.com"))
    #expect(r.content.contains(RuleCompiler.beginSentinel))
    #expect(r.content.contains(RuleCompiler.endSentinel))
}

@Test func ruleIsLabelledWithItsNameInsideBlock() throws {
    let r = try #require(try? RuleCompiler.compile(
        enabled: [NamedRule(name: "测试环境", content: "10.0.0.1 t.com")],
        currentHosts: baseHosts).get())
    #expect(r.content.contains("# ==== 测试环境 ===="))
}

@Test func repeatedCompileIsIdempotent() throws {
    // 最重要的一条：反复开合不能残留、不能丢用户行
    let current = baseHosts + "\n9.9.9.9 keep-me.local\n"
    let rules = [NamedRule(name: "r1", content: "1.1.1.1 a.com")]
    var text = current
    for _ in 0..<20 {
        text = try #require(try? RuleCompiler.compile(enabled: rules, currentHosts: text).get()).content
    }
    #expect(text.components(separatedBy: RuleCompiler.beginSentinel).count == 2)  // 只有一个块
    #expect(text.contains("keep-me.local"))
    #expect(text.contains("localhost"))
    #expect(text.components(separatedBy: "1.1.1.1 a.com").count == 2)             // 不重复堆积
}

@Test func replacesPreviousBlockWhenRulesChange() throws {
    let first = try #require(try? RuleCompiler.compile(
        enabled: [NamedRule(name: "old", content: "1.1.1.1 old.com")],
        currentHosts: baseHosts).get()).content
    let second = try #require(try? RuleCompiler.compile(
        enabled: [NamedRule(name: "new", content: "2.2.2.2 new.com")],
        currentHosts: first).get()).content
    #expect(second.contains("new.com"))
    #expect(second.contains("old.com") == false)
    #expect(second.contains("old") == false)
}

@Test func manuallyEditedBlockIsStillStripped() throws {
    // 用户手工改了块内内容：块边界仍然唯一可信，按哨兵剥离后重写
    let withBlock = try #require(try? RuleCompiler.compile(
        enabled: [NamedRule(name: "a", content: "1.1.1.1 a.com")],
        currentHosts: baseHosts).get()).content
    let tampered = withBlock.replacingOccurrences(of: "1.1.1.1 a.com", with: "6.6.6.6 hacked.com")
    let out = try #require(try? RuleCompiler.compile(
        enabled: [NamedRule(name: "b", content: "2.2.2.2 b.com")],
        currentHosts: tampered).get()).content
    #expect(out.contains("hacked.com") == false)
    #expect(out.contains("b.com"))
}

@Test func unbalancedSentinelRefusesToWrite() {
    // 只有开标签没有闭标签：绝不猜测块范围，拒绝写入让用户先看 diff
    let broken = baseHosts + "\n" + RuleCompiler.beginSentinel + "\n1.1.1.1 orphan.com\n"
    let result = RuleCompiler.compile(enabled: [NamedRule(name: "x", content: "2.2.2.2 x.com")],
                                      currentHosts: broken)
    switch result {
    case .success: Issue.record("必须拒绝写入")
    case .failure(let e):
        guard case .brokenSentinel = e else { Issue.record("错误类型应为 brokenSentinel"); return }
    }
}

@Test func orphanEndSentinelAlsoRefused() {
    let broken = baseHosts + "\n" + RuleCompiler.endSentinel + "\n"
    switch RuleCompiler.compile(enabled: [], currentHosts: broken) {
    case .success: Issue.record("必须拒绝写入")
    case .failure(let e):
        guard case .brokenSentinel = e else { Issue.record("错误类型应为 brokenSentinel"); return }
    }
}

@Test func outputIsLFOnlySingleTrailingNewlineNoBOM() throws {
    let r = try #require(try? RuleCompiler.compile(
        enabled: [NamedRule(name: "a", content: "1.1.1.1 a.com\r\n2.2.2.2 b.com")],
        currentHosts: baseHosts + "\r\n").get())
    #expect(r.content.contains("\r") == false)
    #expect(r.content.hasSuffix("\n"))
    #expect(r.content.hasSuffix("\n\n") == false)
    #expect(r.content.hasPrefix("\u{FEFF}") == false)
}

@Test func statsCountEnabledRulesAndMappings() throws {
    let r = try #require(try? RuleCompiler.compile(
        enabled: [NamedRule(name: "a", content: "1.1.1.1 x.com y.com"),
                  NamedRule(name: "b", content: "# 全是注释\n")],
        currentHosts: baseHosts).get())
    #expect(r.stats.enabledRuleCount == 2)
    #expect(r.stats.mappingCount == 2)
}

@Test func managementOffEmitsCleanHosts() throws {
    // 总开关关掉 = 把托管块整个摘掉，等价于还原
    let withBlock = try #require(try? RuleCompiler.compile(
        enabled: [NamedRule(name: "a", content: "1.1.1.1 a.com")],
        currentHosts: baseHosts).get()).content
    let off = try #require(try? RuleCompiler.compile(enabled: [], currentHosts: withBlock).get())
    #expect(off.content.contains("a.com") == false)
    #expect(off.content.contains(RuleCompiler.beginSentinel) == false)
    #expect(off.content.contains("localhost"))
}
