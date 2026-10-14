import Foundation

/// 执行外部命令的抽象（注入假实现做测试）。
public protocol ProxyCommandRunning: Sendable {
    func run(_ executable: String, _ args: [String]) -> (status: Int32, output: String)
}

public struct ProcessProxyRunner: ProxyCommandRunning {
    public init() {}
    public func run(_ executable: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() }
        catch { return (status: -1, output: String(describing: error)) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

/// 开关 macOS 系统代理（web/secure/socks 三项都指到本地端口）。
///
/// 探测结论（spec §1.1 #33）：`networksetup` 以 admin 用户运行即免密；
/// 但 `set*proxy` 会顺带把 Enabled 置 Yes，关闭必须单独 `…proxystate off`。
public enum SystemProxy {
    public static let networksetup = "/usr/sbin/networksetup"
    public static let route = "/sbin/route"

    public enum SystemProxyError: Error, Equatable {
        case noActiveService
        case commandFailed(String)
    }

    /// 从 `route -n get default` 输出里取活动网卡（如 en0）。
    public static func activeInterface(fromRouteOutput out: String) -> String? {
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                return t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// 从 `networksetup -listallhardwareports` 文本里，把设备名（en0）映射成服务名（Wi-Fi）。
    public static func service(forDevice device: String, hardwarePorts text: String) -> String? {
        var pendingPort: String?
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                pendingPort = String(line.dropFirst("Hardware Port:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Device:") {
                let dev = String(line.dropFirst("Device:".count)).trimmingCharacters(in: .whitespaces)
                if dev == device { return pendingPort }
            }
        }
        return nil
    }

    /// 开启：三条 set（每条都会顺带启用）。
    public static func enableArgs(service: String, httpPort: Int, socksPort: Int) -> [[String]] {
        [
            ["-setwebproxy", service, "127.0.0.1", String(httpPort)],
            ["-setsecurewebproxy", service, "127.0.0.1", String(httpPort)],
            ["-setsocksfirewallproxy", service, "127.0.0.1", String(socksPort)],
        ]
    }

    /// 关闭：三条 state off（set*proxy 不会自己关，必须显式）。
    public static func disableArgs(service: String) -> [[String]] {
        [
            ["-setwebproxystate", service, "off"],
            ["-setsecurewebproxystate", service, "off"],
            ["-setsocksfirewallproxystate", service, "off"],
        ]
    }

    /// 探测当前活动服务名（每次调用都查，网卡可能变）。
    public static func detectService(runner: any ProxyCommandRunning) -> String? {
        let (_, routeOut) = runner.run(route, ["-n", "get", "default"])
        guard let iface = activeInterface(fromRouteOutput: routeOut) else { return nil }
        let (_, ports) = runner.run(networksetup, ["-listallhardwareports"])
        return service(forDevice: iface, hardwarePorts: ports)
    }

    @discardableResult
    public static func enable(httpPort: Int, socksPort: Int,
                              runner: any ProxyCommandRunning = ProcessProxyRunner())
        -> Result<Void, SystemProxyError> {
        guard let svc = detectService(runner: runner) else { return .failure(.noActiveService) }
        for args in enableArgs(service: svc, httpPort: httpPort, socksPort: socksPort) {
            let (st, out) = runner.run(networksetup, args)
            if st != 0 { return .failure(.commandFailed(out.isEmpty ? "\(args)" : out)) }
        }
        return .success(())
    }

    @discardableResult
    public static func disable(runner: any ProxyCommandRunning = ProcessProxyRunner())
        -> Result<Void, SystemProxyError> {
        guard let svc = detectService(runner: runner) else { return .failure(.noActiveService) }
        for args in disableArgs(service: svc) {
            let (st, out) = runner.run(networksetup, args)
            if st != 0 { return .failure(.commandFailed(out.isEmpty ? "\(args)" : out)) }
        }
        return .success(())
    }
}
