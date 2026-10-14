import Foundation
import Testing
@testable import ToolboxKit

private final class SysProxyRunner: ProxyCommandRunning, @unchecked Sendable {
    var routeOut = ""
    var portsOut = ""
    var failOn: ([String]) -> Bool = { _ in false }
    var ran: [(String, [String])] = []
    func run(_ e: String, _ a: [String]) -> (status: Int32, output: String) {
        ran.append((e, a))
        if e.hasSuffix("/route") { return (status: 0, output: routeOut) }
        let out = a.first == "-listallhardwareports" ? portsOut : ""
        return (status: failOn(a) ? 1 : 0, output: out)
    }
}

private let portsText = """
Hardware Port: Wi-Fi
Device: en0
Ethernet Address: aa:bb

Hardware Port: Thunderbolt Bridge
Device: bridge0
Ethernet Address: cc:dd
"""

@Test func parsesActiveInterface() {
    #expect(SystemProxy.activeInterface(fromRouteOutput: "route to: default\ninterface: en0\n") == "en0")
    #expect(SystemProxy.activeInterface(fromRouteOutput: "no interface line") == nil)
}

@Test func mapsDeviceToServiceName() {
    #expect(SystemProxy.service(forDevice: "en0", hardwarePorts: portsText) == "Wi-Fi")
    #expect(SystemProxy.service(forDevice: "bridge0", hardwarePorts: portsText) == "Thunderbolt Bridge")
    #expect(SystemProxy.service(forDevice: "en9", hardwarePorts: portsText) == nil)
}

@Test func enableArgsSetThreeProxies() {
    let args = SystemProxy.enableArgs(service: "Wi-Fi", httpPort: 10809, socksPort: 10808)
    #expect(args[0] == ["-setwebproxy", "Wi-Fi", "127.0.0.1", "10809"])
    #expect(args[1] == ["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "10809"])
    #expect(args[2] == ["-setsocksfirewallproxy", "Wi-Fi", "127.0.0.1", "10808"])
}

@Test func disableArgsAreStateOff() {
    // set*proxy 会顺带启用，关闭必须用独立的 proxystate off（§1.1 #33）
    let args = SystemProxy.disableArgs(service: "Wi-Fi")
    #expect(args == [
        ["-setwebproxystate", "Wi-Fi", "off"],
        ["-setsecurewebproxystate", "Wi-Fi", "off"],
        ["-setsocksfirewallproxystate", "Wi-Fi", "off"],
    ])
}

@Test func enableIssuesDetectedServiceCommands() throws {
    let r = SysProxyRunner()
    r.routeOut = "interface: en0\n"
    r.portsOut = portsText
    let result = SystemProxy.enable(httpPort: 10809, socksPort: 10808, runner: r)
    if case .failure(let e) = result { Issue.record("不该失败: \(e)") }
    let sets = r.ran.filter { $0.1.first?.contains("proxy") == true && $0.1.first != "-listallhardwareports" }
    #expect(sets.count == 3)
    #expect(sets.allSatisfy { $0.1.contains("Wi-Fi") })
}

@Test func enableFailsWhenNoActiveService() {
    let r = SysProxyRunner()
    r.routeOut = "interface: en9\n"      // 不在硬件表里
    r.portsOut = portsText
    if case .success = SystemProxy.enable(httpPort: 1, socksPort: 2, runner: r) {
        Issue.record("探测不到服务应失败")
    }
    // 探测失败就不该再下发任何 set 命令
    let setCmds = r.ran.filter { ($0.1.first ?? "").hasPrefix("-set") }
    #expect(setCmds.isEmpty)
}

@Test func enableReportsCommandFailure() {
    let r = SysProxyRunner()
    r.routeOut = "interface: en0\n"
    r.portsOut = portsText
    r.failOn = { $0.first == "-setsocksfirewallproxy" }
    if case .failure(.commandFailed) = SystemProxy.enable(httpPort: 10809, socksPort: 10808, runner: r) {}
    else { Issue.record("第三条失败应上报 commandFailed") }
}

@Test func disableIssuesThreeStateOff() throws {
    let r = SysProxyRunner()
    r.routeOut = "interface: en0\n"
    r.portsOut = portsText
    if case .failure(let e) = SystemProxy.disable(runner: r) { Issue.record("disable 不该失败: \(e)") }
    let offs = r.ran.filter { $0.1.first?.hasSuffix("proxystate") == true }
    #expect(offs.count == 3)
}

// MARK: 延迟探针的代理字典（纯函数部分）

@Test func socksProxyDictPointsAtLoopback() {
    let d = LatencyProbe.socksProxyDict(port: 10808)
    #expect(d["SOCKSEnabled"] as? Int == 1)
    #expect(d["SOCKSProxy"] as? String == "127.0.0.1")
    #expect(d["SOCKSPort"] as? Int == 10808)
}

@Test func httpProxyDictPointsAtLoopback() {
    let d = LatencyProbe.httpProxyDict(port: 10809)
    #expect(d["HTTPEnable"] as? Int == 1)
    #expect(d["HTTPPort"] as? Int == 10809)
}
