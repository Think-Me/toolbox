import Foundation

/// 一次性系统授权（spec §4.4）。
///
/// 两条授权的作用域刻意做得极窄：
/// - hosts 组可写：只放开一个文件的写位，之后写 /etc/hosts 免弹窗
/// - DNS sudoers：只允许两条**精确到参数**的命令，不含任何通配
public enum Provisioning {
    public enum Step: Equatable, Sendable { case hostsGroupWritable, dnsSudoers }
    public enum ProvisionError: Error, Equatable {
        case cancelled          // 用户在密码框点了取消
        case validationFailed(String)
        case installFailed(String)
        case notEffective(String)   // 装完了但探测仍不通过（见 §4.4 的 includedir 未知项）
    }

    public static let sudoersPath = "/etc/sudoers.d/toolbox"
    static let dscacheutil = "/usr/bin/dscacheutil"
    static let killall = "/usr/bin/killall"

    /// 生成 sudoers 片段。纯函数，单独测。
    public static func sudoersContent(user: String) -> String {
        """
        # Toolbox — 仅允许刷新 DNS 缓存。删除本文件即可撤销：
        #   sudo rm \(sudoersPath)
        Cmnd_Alias TOOLBOX_DNS_FLUSH = \(dscacheutil) -flushcache, \(killall) -HUP mDNSResponder
        \(user) ALL=(root) NOPASSWD: TOOLBOX_DNS_FLUSH
        """
    }

    /// 不许出现通配或省略参数，否则等于把 root 交出去。
    public static func isSudoersContentSafe(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }
        guard lines.count == 2 else { return false }
        let first = String(lines[0])
        guard first.hasPrefix("Cmnd_Alias TOOLBOX_DNS_FLUSH = ") else { return false }
        if first.contains("*") { return false }
        // 每条命令都必须带死参数
        let cmds = first.dropFirst("Cmnd_Alias TOOLBOX_DNS_FLUSH = ".count)
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard cmds.count == 2 else { return false }
        guard cmds[0] == "\(dscacheutil) -flushcache",
              cmds[1] == "\(killall) -HUP mDNSResponder" else { return false }
        let second = String(lines[1])
        return second.hasSuffix("ALL=(root) NOPASSWD: TOOLBOX_DNS_FLUSH") && !second.contains("*")
    }

    /// 把 shell 片段包进 `do shell script ... with administrator privileges`。
    /// 一次密码输入，之后该步骤永久免弹窗。
    static func adminScript(_ body: String) -> String {
        "do shell script \"\(body.replacingOccurrences(of: "\"", with: "\\\""))\" "
            + "with administrator privileges "
            + "with prompt \"Toolbox 需要一次性授权\""
    }

    @discardableResult
    public static func run(_ step: Step) async -> Result<Void, ProvisionError> {
        switch step {
        case .hostsGroupWritable:
            return await runAppleScript(
                adminScript("chown root:admin /etc/hosts && chmod g+w /etc/hosts"))
        case .dnsSudoers:
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("toolbox-sudoers-\(UUID().uuidString)")
            do {
                try sudoersContent(user: NSUserName()).write(to: tmp, atomically: true,
                                                            encoding: .utf8)
            } catch {
                return .failure(.installFailed("写临时文件失败: \(error.localizedDescription)"))
            }
            defer { try? FileManager.default.removeItem(at: tmp) }
            // 顺序不可调换：先 visudo 校验，通过了才 install。
            // 改坏 /etc/sudoers.d 会让 sudo 行为异常，绝不能先写再验。
            let body = "\(ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp")"
            _ = body
            let script = adminScript(
                "/usr/sbin/visudo -cf \(shellQuote(tmp.path)) "
                + "&& /usr/bin/install -m 0440 -o root -g wheel "
                + "\(shellQuote(tmp.path)) \(sudoersPath)")
            let res = await runAppleScript(script)
            guard case .success = res else { return res }
            // 装完必须探测：本机 /etc/sudoers 是否 include 了 sudoers.d 无法事先确认（§4.4）
            if PermissionProbes.live.dnsFlush() == true { return .success(()) }
            return .failure(.notEffective(
                """
                文件已装到 \(sudoersPath)，但 `sudo -n` 探测仍不通过。
                最可能的原因是这台机器的 /etc/sudoers 没有 #includedir /etc/sudoers.d。
                撤销：sudo rm \(sudoersPath)
                替代方案：不装 sudoers，切换规则时弹一次密码刷 DNS（功能不受影响）。
                """))
        }
    }

    static func shellQuote(_ s: String) -> String { "'\(s)'" }

    private static func runAppleScript(_ source: String) async -> Result<Void, ProvisionError> {
        await withCheckedContinuation { (cont: CheckedContinuation<Result<Void, ProvisionError>, Never>) in
            // NSAppleScript 非线程安全：在这里新建实例、只在这个线程用。
            // 放后台是因为 executeAndReturnError 会阻塞等用户输密码。
            DispatchQueue.global(qos: .userInitiated).async {
                var info: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&info)
                guard let info else {
                    cont.resume(returning: .success(())); return
                }
                let code = (info["NSAppleScriptErrorNumber"] as? Int) ?? 0
                let msg = (info["NSAppleScriptErrorMessage"] as? String) ?? info.description
                // -128 = 用户在密码框点了取消，要和其他失败区分开
                cont.resume(returning: code == -128
                            ? .failure(.cancelled)
                            : .failure(.validationFailed(msg)))
            }
        }
    }

    public static func uninstallDNSudoers() async -> Result<Void, ProvisionError> {
        await runAppleScript(adminScript("rm -f \(sudoersPath)"))
    }
}
