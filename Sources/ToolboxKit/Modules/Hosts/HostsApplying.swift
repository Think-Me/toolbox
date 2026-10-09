import Foundation

public protocol DnsFlushing: Sendable {
    func flush() -> DnsFlushOutcome
}
extension DnsFlusher: DnsFlushing {}

public struct ApplyReport: Sendable, Equatable {
    public let conflicts: [DomainConflict]
    public let dns: DnsFlushOutcome
    /// 实际写盘字节数，0 表示内容无变化而跳过
    public let writtenBytes: Int
}

public enum ApplyOutcome: Sendable {
    case success(ApplyReport)
    /// 哨兵不配对等：一个字都没写
    case refused(String)
    case failed(String)
}

/// 把"读当前 hosts → 解析规则内容 → 编译 → 写 → 刷 DNS"收成一步。
///
/// 做成 actor 是硬要求：连点两条规则会触发两次 apply，
/// 两个"读-改-写"并发跑在同一个系统文件上会互相覆盖，
/// 结果取决于谁后写完 —— 这类 bug 在真机上几乎无法复现，只能从结构上杜绝。
public actor HostsApplying {
    private let writer: any HostsWriting
    private let dns: any DnsFlushing
    private var lastWritten: String?

    public init(writer: any HostsWriting, dns: any DnsFlushing = DnsFlusher()) {
        self.writer = writer
        self.dns = dns
    }

    public func apply(library: HostsLibrary) async throws -> ApplyOutcome {
        let current: String
        do {
            current = try writer.read()
        } catch {
            return .failed("读取 /etc/hosts 失败：\(error)")
        }

        // managementOn 关掉 = 摘掉托管块（等价于还原），不写任何规则内容
        let enabled: [NamedRule] = library.managementOn ? resolve(library.enabledRules) : []

        let compiled: CompileResult
        do {
            compiled = try RuleCompiler.compile(enabled: enabled, currentHosts: current)
                .get()
        } catch let e as CompileError {
            // 拒绝必须发生在任何写入之前：猜错块范围会吞掉用户手写的行
            return .refused(describe(e))
        } catch {
            return .failed("编译规则失败：\(error)")
        }

        guard compiled.content != current else {
            // 内容没变就不碰文件：少一次无谓的备份与写盘
            return .success(ApplyReport(conflicts: compiled.conflicts, dns: .ok,
                                        writtenBytes: 0))
        }
        do {
            try writer.write(compiled.content)
        } catch {
            return .failed("写入 /etc/hosts 失败：\(error)")
        }
        lastWritten = compiled.content
        let flush = dns.flush()
        return .success(ApplyReport(conflicts: compiled.conflicts, dns: flush,
                                    writtenBytes: compiled.content.utf8.count))
    }

    public func restoreOriginal() async throws -> ApplyOutcome {
        do {
            try writer.restoreOriginal()
        } catch {
            return .failed("还原原始 hosts 失败：\(error)")
        }
        return .success(ApplyReport(conflicts: [], dns: dns.flush(), writtenBytes: -1))
    }

    /// 把每条规则的内容取出来。localFile / remote 读不到就跳过并记录原因，
    /// 绝不让一条坏规则把整个开关动作拖失败。
    private func resolve(_ rules: [Rule]) -> [NamedRule] {
        rules.compactMap { rule in
            switch rule.kind {
            case .inline(let content):
                return NamedRule(name: rule.name, content: content)
            case .localFile(let path):
                guard let s = try? String(contentsOfFile: path, encoding: .utf8) else {
                    return NamedRule(name: rule.name, content: "# 读不到 \(path)")
                }
                return NamedRule(name: rule.name, content: s)
            case .remote(_, let cached):
                return NamedRule(name: rule.name, content: cached ?? "# 尚未同步过")
            }
        }
    }

    private func describe(_ e: CompileError) -> String {
        switch e {
        case .brokenSentinel(let reason):
            return """
            /etc/hosts 里的 Toolbox 托管块标记不完整（\(reason)）。
            为避免误删你手写的行，本次没有写入任何内容。
            请打开 /etc/hosts 检查 "# >>> Toolbox managed >>>" 与 "# <<< Toolbox managed <<<"
            是否成对，或点「还原原始 hosts」后重试。
            """
        }
    }
}
