import Foundation

public protocol DnsCommandRunning: Sendable {
    func run(executable: String, arguments: [String]) -> (status: Int32, stderr: String)
}

/// 真实现：跑 `sudo -n -k <cmd>`。
public struct ProcessDnsRunner: DnsCommandRunning {
    public init() {}
    public func run(executable: String, arguments: [String]) -> (status: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return (-1, String(describing: error))
        }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

public enum DnsFlushOutcome: Equatable {
    case ok
    /// sudoers 没装 / 本机 sudoers 不 include sudoers.d
    case needsProvisioned(String)
    case failed(String)
}

/// 刷新 DNS 缓存。写完 hosts 必须刷，否则旧 IP 会残留几十秒到几分钟，
/// 用户会觉得"切了规则没生效"——这是最容易被当成 bug 的地方。
public struct DnsFlusher: Sendable {
    private let runner: any DnsCommandRunning

    public init(runner: any DnsCommandRunning = ProcessDnsRunner()) {
        self.runner = runner
    }

    public static let sudo = "/usr/bin/sudo"
    public static let dscacheutil = "/usr/bin/dscacheutil"
    public static let killall = "/usr/bin/killall"

    /// 两条命令都要跑：`dscacheutil -flushcache` 清 DNS 缓存，
    /// `killall -HUP mDNSResponder` 让 mDNSResponder 重读 /etc/hosts。
    ///
    /// `-k` 是必须的：不带它，用户 5 分钟内的 sudo ticket 缓存会让探测/执行
    /// 在**没装 sudoers 的机器上也返回 0**，得到假阳性。
    public func flush() -> DnsFlushOutcome {
        let first = runner.run(executable: Self.sudo,
                               arguments: ["-n", "-k", Self.dscacheutil, "-flushcache"])
        if first.status != 0 {
            return classify(first.stderr, code: first.status)
        }
        let second = runner.run(executable: Self.sudo,
                                arguments: ["-n", "-k", Self.killall, "-HUP", "mDNSResponder"])
        if second.status != 0 {
            // 缓存已刷、只是没 HUP 到 mDNSResponder：仍然算需要授权，
            // 但要把原因说清楚，别让用户以为整个操作失败了
            return classify(second.stderr, code: second.status)
        }
        return .ok
    }

    private func classify(_ stderr: String, code: Int32) -> DnsFlushOutcome {
        if stderr.localizedCaseInsensitiveContains("password") || code == 1 {
            return .needsProvisioned(
                "刷新 DNS 缓存需要免密授权（sudo -n 被要求输入密码）。"
                + "请在 设置 → 权限 里点「刷新 DNS 缓存」的\"去授权\"。")
        }
        return .failed(stderr.isEmpty ? "退出码 \(code)" : stderr)
    }
}
