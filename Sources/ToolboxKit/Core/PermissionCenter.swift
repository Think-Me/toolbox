import ApplicationServices
import CoreGraphics
import Darwin

public enum Permission: String, CaseIterable, Sendable {
    case accessibility, screenRecording, hostsWritable, dnsFlush
}

public enum PermissionState: Equatable, Sendable {
    case granted, denied, unknown
}

/// 四个权限探针。返回 `nil` = unknown（探测本身失败），
/// 与 `false`（明确被拒绝/未授权）是两件事，不许混——unknown 时 UI 应给"重试"而不是"去授权"。
public struct PermissionProbes: Sendable {
    public var accessibility: @Sendable () -> Bool?
    public var screenRecording: @Sendable () -> Bool?
    public var hostsWritable: @Sendable () -> Bool?
    public var dnsFlush: @Sendable () -> Bool?

    public init(accessibility: @escaping @Sendable () -> Bool?,
                screenRecording: @escaping @Sendable () -> Bool?,
                hostsWritable: @escaping @Sendable () -> Bool?,
                dnsFlush: @escaping @Sendable () -> Bool?) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.hostsWritable = hostsWritable
        self.dnsFlush = dnsFlush
    }

    /// 全 denied 的固定探针：给单测造 AppModel 用，避免测试去碰真实系统权限。
    public static let constantDenied = PermissionProbes(
        accessibility: { false }, screenRecording: { false },
        hostsWritable: { false }, dnsFlush: { false })

    public static let hostsPath = "/etc/hosts"
    public static let sudoersPath = "/etc/sudoers.d/toolbox"

    public static let live = PermissionProbes(
        accessibility: { AXIsProcessTrusted() },
        screenRecording: { CGPreflightScreenCaptureAccess() },
        hostsWritable: {
            // 权威判定就是真开一次写句柄（不带 O_TRUNC，不会截断文件）。
            // 只看 st_mode 位会在"真正要写的那一秒"才失败：属主/组可被系统升级重置。
            let fd = open(Self.hostsPath, O_WRONLY)
            if fd >= 0 { close(fd); return true }
            return errno == EACCES ? false : nil     // 其它 errno（如 ENOENT）= unknown
        },
        dnsFlush: {
            // 必须带 -k：`sudo -n` 会命中用户 5 分钟内的 sudo ticket 缓存，
            // 那时即使我们的 sudoers 条目不存在也会返回 0，得到假的 granted。
            // 代价是顺手清掉用户的 sudo 时间戳（下次 sudo 需重新输密码）。
            // 实测 `sudo -n -l <cmd>` 不能替代：它本身就要认证，区分不出"未授权"和"需密码"。
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-n", "-k", "/usr/bin/dscacheutil", "-flushcache"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit() } catch { return nil }
            return p.terminationStatus == 0
        })
}

public struct PermissionRow: Equatable, Sendable {
    public var permission: Permission
    public var state: PermissionState
    public var actionTitle: String?
    public var detail: String
}

public struct PermissionCenter: Sendable {
    public let probes: PermissionProbes

    public init(probes: PermissionProbes) { self.probes = probes }

    public func snapshot() -> [PermissionRow] {
        Permission.allCases.map { p in
            let raw: Bool?
            switch p {
            case .accessibility:   raw = probes.accessibility()
            case .screenRecording: raw = probes.screenRecording()
            case .hostsWritable:   raw = probes.hostsWritable()
            case .dnsFlush:        raw = probes.dnsFlush()
            }
            let state: PermissionState
            switch raw {
            case .some(true):  state = .granted
            case .some(false): state = .denied
            case .none:        state = .unknown
            }
            let action: String?
            switch state {
            case .granted: action = nil
            case .denied:  action = "去授权"
            case .unknown: action = "重试探测"
            }
            return PermissionRow(permission: p, state: state,
                                 actionTitle: action, detail: Self.detail(for: p))
        }
    }

    public static func detail(for p: Permission) -> String {
        switch p {
        case .accessibility:
            return "剪贴板选中后自动粘贴需要辅助功能权限；缺失时只会复制到剪贴板、不会自动粘贴。"
        case .screenRecording:
            return "截图需要屏幕录制权限；授权后必须重启 Toolbox 才生效。未授权时系统可能返回黑屏而不报错。"
        case .hostsWritable:
            return "需要一次性执行 chown root:admin /etc/hosts && chmod g+w /etc/hosts，此后写 /etc/hosts 免弹窗。"
        case .dnsFlush:
            return "切换规则后刷新 DNS 缓存需要一条仅允许 dscacheutil/killall 的 NOPASSWD sudoers。"
        }
    }

    public func requestAccessibility() {
        // kAXTrustedCheckOptionPrompt 是全局 `var CFString!`，Swift 6 拒绝引用；
        // 该常量值恒为这个字符串，直接用字面值。
        let opts: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    public func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }
}
