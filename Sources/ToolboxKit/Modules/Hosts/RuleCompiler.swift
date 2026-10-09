import Foundation

/// 把启用的规则编译成完整的 /etc/hosts 内容。
///
/// **托管块模型**（spec §4.2）：本 App 只在自己那对哨兵注释之间写内容，
/// 块外的行原样保留。这样反复开合规则既不残留、也永不丢用户手写的行，
/// 而且不需要硬编码"127.0.0.1 localhost 之类必须保留"的白名单。
public enum RuleCompiler {
    public static let beginSentinel = "# >>> Toolbox managed >>>"
    public static let endSentinel = "# <<< Toolbox managed <<<"

    public static func compile(enabled: [NamedRule],
                               currentHosts: String) -> Result<CompileResult, CompileError> {
        let lines = splitLines(currentHosts)
        let keep: [String]
        do {
            keep = try nonManagedLines(lines)
        } catch {
            return .failure(error as! CompileError)
        }

        var out = trimTrailingBlanks(keep).joined(separator: "\n")
        var mappingCount = 0
        if !enabled.isEmpty {
            var body = ""
            for rule in enabled {
                let content = normalizeContent(rule.content)
                body += "# ==== \(rule.name) ====\n"
                if !content.isEmpty { body += content }
                mappingCount += parseMappings(rule.content).count
            }
            out += "\n\n" + beginSentinel + "\n" + body + endSentinel
        }
        return .success(CompileResult(
            content: normalizeDocument(out),
            conflicts: conflicts(enabled),
            stats: CompileStats(enabledRuleCount: enabled.count, mappingCount: mappingCount)))
    }

    // MARK: 解析

    /// 逐行解析 `IP 域名 [域名...]`。容忍注释、空行、CRLF、行尾空白、一行多域名。
    public static func parseMappings(_ content: String) -> [HostsMapping] {
        var out: [HostsMapping] = []
        for raw in splitLines(content) {
            var line = raw
            // 去掉行内注释（# 或 //）
            for marker in ["#", "//"] {
                if let r = line.range(of: marker) { line.removeSubrange(r.lowerBound..<line.endIndex) }
            }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline })
                              .map(String.init)
            guard tokens.count >= 2 else { continue }
            let ip = tokens[0]
            guard isIPAddress(ip) else { continue }     // "notanip line" 这种直接跳过
            for d in tokens.dropFirst() { out.append(HostsMapping(ip: ip, domain: d)) }
        }
        return out
    }

    /// 只判断"像不像 IP"，不做严格校验：hosts 里写错 IP 由系统解析时自然失败，
    /// 我们没必要在这里当守门员把 IPv6 的少见写法误杀。
    static func isIPAddress(_ s: String) -> Bool {
        if s.contains(":") {
            return s.count >= 2 && s.allSatisfy { $0.isHexDigit || $0 == ":" }
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isNumber)
        }
    }

    /// 同一域名被多条启用规则指向不同 IP → 报冲突（只上报不阻断，
    /// 实际解析取第一条，符合用户预期，但值得提醒）。
    public static func conflicts(_ rules: [NamedRule]) -> [DomainConflict] {
        var byDomain: [String: [DomainConflict.Side]] = [:]
        var order: [String] = []
        for rule in rules {
            for m in parseMappings(rule.content) {
                if byDomain[m.domain] == nil { order.append(m.domain) }
                byDomain[m.domain, default: []].append(.init(ruleName: rule.name, ip: m.ip))
            }
        }
        return order.compactMap { domain in
            let sides = byDomain[domain] ?? []
            let ips = Set(sides.map(\.ip))
            guard ips.count > 1 else { return nil }
            // 同名同 IP 重复出现不算冲突，去重后仍多条才算
            var seen = Set<String>()
            let distinct = sides.filter { seen.insert("\($0.ruleName)|\($0.ip)").inserted }
            guard Set(distinct.map(\.ip)).count > 1 else { return nil }
            return DomainConflict(domain: domain, mappings: distinct)
        }
    }

    // MARK: 哨兵块

    /// 摘掉托管块，返回块外的行。哨兵不配对时抛错而不是猜。
    static func nonManagedLines(_ lines: [String]) throws -> [String] {
        let begins = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == beginSentinel }
        let ends = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == endSentinel }
        guard !begins.isEmpty, !ends.isEmpty else {
            if begins.isEmpty && ends.isEmpty { return lines }
            if begins.isEmpty {
                throw CompileError.brokenSentinel(reason: "发现闭合标签但缺少开始标签")
            }
            throw CompileError.brokenSentinel(reason: "发现开始标签但缺少闭合标签")
        }
        guard begins.count == 1, ends.count == 1 else {
            throw CompileError.brokenSentinel(reason: "哨兵标签出现多次（\(begins.count)/\(ends.count)），无法确定块范围")
        }
        guard begins[0] < ends[0] else {
            throw CompileError.brokenSentinel(reason: "闭合标签在开始标签之前")
        }
        var out: [String] = []
        for (i, line) in lines.enumerated() where i < begins[0] || i > ends[0] {
            out.append(line)
        }
        return out
    }

    // MARK: 文本规范化

    static func splitLines(_ s: String) -> [String] {
        s.replacingOccurrences(of: "\r\n", with: "\n")
         .replacingOccurrences(of: "\r", with: "\n")
         .components(separatedBy: "\n")
    }

    /// 规则内容：LF、去掉首尾空行、保证结尾恰好一个换行
    static func normalizeContent(_ s: String) -> String {
        var lines = splitLines(s)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    static func trimTrailingBlanks(_ lines: [String]) -> [String] {
        var l = lines
        while let last = l.last, last.trimmingCharacters(in: .whitespaces).isEmpty { l.removeLast() }
        return l
    }

    /// 整份文档：去 BOM、LF、结尾恰好一个换行
    static func normalizeDocument(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\r", with: "\n")
        if out.hasPrefix("\u{FEFF}") { out.removeFirst() }
        while out.hasSuffix("\n\n") { out.removeLast() }
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }
}
