// 按 PID 列出本进程在屏的窗口，用来证明浮层/贴图**真的**上了 WindowServer，
// 而不是只看 AppKit 的 isVisible（裸二进制下后者会骗人，见 docs/manual-qa.md）。
// 用法：swiftc -O -o /tmp/wincheck Scripts/wincheck.swift && /tmp/wincheck <pid>
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    print("usage: wincheck <pid>"); exit(2)
}
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                       kCGNullWindowID) as? [[String: Any]]) ?? []
let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
for w in mine {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("layer=\(w[kCGWindowLayer as String] ?? "?") "
        + "bounds=\(b["X"] ?? "?"),\(b["Y"] ?? "?") \(b["Width"] ?? "?")x\(b["Height"] ?? "?") "
        + "alpha=\(w[kCGWindowAlpha as String] ?? "?")")
}
print("count=\(mine.count)")
