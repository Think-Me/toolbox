import AppKit

extension NSColor {
    /// 从 `#RRGGBB` 构造。放大镜的取色回显要用。
    /// 解析失败返回 nil，绝不返回一个黑色骗人——黑色看起来"正常"，
    /// 用户会以为是屏幕本身黑，而不是取色失败。
    public convenience init?(hexString: String) {
        var s = hexString
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}
