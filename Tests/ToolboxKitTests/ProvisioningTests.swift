import Testing
@testable import ToolboxKit

@Test func sudoersContentUsesExactCommands() {
    let text = Provisioning.sudoersContent(user: "ebertwiseman")
    #expect(text.contains("Cmnd_Alias TOOLBOX_DNS_FLUSH = /usr/bin/dscacheutil -flushcache, /usr/bin/killall -HUP mDNSResponder"))
    #expect(text.contains("ebertwiseman ALL=(root) NOPASSWD: TOOLBOX_DNS_FLUSH"))
    #expect(Provisioning.isSudoersContentSafe(text))
}

@Test func safetyCheckRejectsWildcards() {
    let bad = Provisioning.sudoersContent(user: "bob").replacingOccurrences(of: "-flushcache", with: "*")
    #expect(Provisioning.isSudoersContentSafe(bad) == false)
}

@Test func safetyCheckRejectsMissingParameters() {
    // 只给可执行路径不给参数 = 允许该程序任意用法，等于交出 root
    let tooLoose = """
    Cmnd_Alias TOOLBOX_DNS_FLUSH = /usr/bin/dscacheutil, /usr/bin/killall -HUP mDNSResponder
    bob ALL=(root) NOPASSWD: TOOLBOX_DNS_FLUSH
    """
    #expect(Provisioning.isSudoersContentSafe(tooLoose) == false)
}

@Test func safetyCheckRejectsWrongLineCount() {
    #expect(Provisioning.isSudoersContentSafe("# only a comment") == false)
    #expect(Provisioning.isSudoersContentSafe("") == false)
}

@Test func adminScriptQuotesInnerDoubleQuotes() {
    let s = Provisioning.adminScript("echo \"hi\"")
    #expect(s.contains("with administrator privileges"))
    // 内部的双引号必须被转义，否则 AppleScript 字符串会提前截断
    #expect(s.contains("\\\"hi\\\""))
}

@Test func shellQuoteProtectsSpaces() {
    #expect(Provisioning.shellQuote("/tmp/a b/c") == "'/tmp/a b/c'")
}
