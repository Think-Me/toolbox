import Foundation

/// xray Stats API 的累计字节数（两个方向各自单调递增）。
public struct TrafficCounters: Equatable, Sendable {
    public var up: Int64
    public var down: Int64
    public init(up: Int64 = 0, down: Int64 = 0) { self.up = up; self.down = down }
}

/// 实时速率（字节/秒）。
public struct TrafficSample: Equatable, Sendable {
    public var upPerSecond: Double
    public var downPerSecond: Double

    public static let zero = TrafficSample(upPerSecond: 0, downPerSecond: 0)

    public init(upPerSecond: Double, downPerSecond: Double) {
        self.upPerSecond = upPerSecond
        self.downPerSecond = downPerSecond
    }

    /// 形如 "↑ 12.3 KB/s  ↓ 1.2 MB/s"
    public var displayText: String {
        "↑ \(TrafficRateFormatter.string(upPerSecond))  ↓ \(TrafficRateFormatter.string(downPerSecond))"
    }

    /// 用两次累计采样求速率。计数回退（内核重启清零）或时间差非正时返回 nil。
    public static func rate(from previous: TrafficCounters, to current: TrafficCounters,
                            elapsed: TimeInterval) -> TrafficSample? {
        guard elapsed > 0, current.up >= previous.up, current.down >= previous.down else { return nil }
        return TrafficSample(
            upPerSecond: Double(current.up - previous.up) / elapsed,
            downPerSecond: Double(current.down - previous.down) / elapsed)
    }
}

public enum TrafficRateFormatter {
    /// 1024 进制的 B/s、KB/s、MB/s、GB/s。
    public static func string(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let number = unit == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(number) \(units[unit])"
    }
}

public enum XrayStatsParser {
    /// 解析 `xray api statsquery` 的 JSON，只累加 socks-in / http-in 的上下行。
    ///
    /// 输出形如：
    /// `{"stat":[{"name":"inbound>>>http-in>>>traffic>>>uplink","value":"1691"}]}`
    /// `value` 在不同版本里可能是字符串或数字，两种都接受。
    /// 必须排除 `inbound>>>api>>>…`，那是查询本身产生的流量，会在每次轮询时放大读数。
    public static func traffic(from data: Data) -> TrafficCounters? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stat = root["stat"] as? [[String: Any]] else { return nil }

        var up: Int64 = 0
        var down: Int64 = 0
        for entry in stat {
            guard let name = entry["name"] as? String,
                  let bytes = int64(entry["value"]) else { continue }
            let parts = name.split(separator: ">>>", omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0] == "inbound", parts[2] == "traffic" else { continue }
            guard parts[1] == "socks-in" || parts[1] == "http-in" else { continue }
            switch parts[3] {
            case "uplink": up += bytes
            case "downlink": down += bytes
            default: break
            }
        }
        return TrafficCounters(up: up, down: down)
    }

    private static func int64(_ any: Any?) -> Int64? {
        switch any {
        case let s as String: return Int64(s)
        case let n as NSNumber: return n.int64Value
        default: return nil
        }
    }
}

/// 通过内置内核自带的 `xray api statsquery` 读取 Stats API。
///
/// 调用方必须在后台线程/任务里运行：这里会同步 `waitUntilExit`。
public enum XrayStatsClient {
    public static func query(executable: URL, port: Int) -> TrafficCounters? {
        let p = Process()
        p.executableURL = executable
        p.arguments = ["api", "statsquery",
                       "--server=127.0.0.1:\(port)",
                       "-pattern", "inbound>>>",
                       "-timeout", "3"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return nil
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return XrayStatsParser.traffic(from: data)
    }
}
