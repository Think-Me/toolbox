import Darwin
import Foundation

/// 取一个当前空闲的本地 TCP 端口。
///
/// 用于 xray Stats API 入口：写死端口可能被别的软件占用，导致整个内核起不来。
/// 做法是先 bind `127.0.0.1:0` 让内核分配端口，读到端口号后立刻关闭。
/// 从关闭到 xray 真正监听之间存在极小的被抢占窗口，概率可忽略；
/// 万一真的冲突，会走 `XrayRunner` 现有的崩溃退避逻辑。
public enum LocalFreePort {
    public static func allocate() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        guard got == 0 else { return nil }

        let port = Int(UInt16(bigEndian: actual.sin_port))
        return port > 0 ? port : nil
    }
}
