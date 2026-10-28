import Foundation

/// 检测"App 还在运行，但磁盘上的 bundle 已被替换/删除"。
///
/// macOS 对合成事件是**逐事件按盘上文件校验**的：正在运行的进程被
/// `make app/dmg` 在脚下替换掉 bundle 之后，TCC 数据库仍显示已授权、
/// `AXIsProcessTrusted()` 仍返回 true，但发出去的键盘事件会被 WindowServer
/// 静默丢弃——所有 App 都"粘贴不上"且零提示（实测排查成本极高）。
///
/// 启动时记下可执行文件的 inode + 大小 + mtime，发合成按键前再对一次。
public final class BundleIntegrity: Sendable {
    public static let shared = BundleIntegrity()

    private struct Snapshot: Equatable {
        let inode: ino_t
        let size: off_t
        let mtime: Int64
    }

    private let url: URL?
    private let boot: Snapshot?

    public init(url: URL? = Bundle.main.executableURL) {
        self.url = url
        self.boot = url.flatMap(Self.snapshot)
    }

    /// true = 盘上可执行文件已丢失或换过（旧进程注入事件必然失效）。
    /// 启动时就读不到、或现在仍然读到的路径没变，都不误伤：
    /// 判不准时宁可放行，让老逻辑继续工作。
    public var isStale: Bool {
        guard let url, let boot else { return false }
        return Self.snapshot(url) != boot
    }

    private static func snapshot(_ url: URL) -> Snapshot? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Snapshot(inode: st.st_ino, size: st.st_size,
                        mtime: Int64(st.st_mtimespec.tv_sec))
    }
}
