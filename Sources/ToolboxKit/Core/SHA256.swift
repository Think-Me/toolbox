import CryptoKit
import Foundation

public enum SHA256 {
    /// 小写十六进制。用作 MediaStore 的内容寻址文件名，所以必须稳定且可安全当路径片段用。
    public static func hex(_ data: Data) -> String {
        // 本文件里的枚举也叫 SHA256，会遮蔽 CryptoKit 的同名类型，必须全限定
        CryptoKit.SHA256.hash(data: data)
            .compactMap { String(format: "%02x", $0) }.joined()
    }

    public static func hex(_ string: String) -> String {
        hex(Data(string.utf8))
    }

    /// 只允许 [0-9a-f]{64}。文件名来自外部输入时必须先过这一关，
    /// 否则 "../../etc/hosts" 这种 sha 会把写文件变成任意路径写。
    public static func isPlausibleHex(_ s: String) -> Bool {
        guard s.count == 64 else { return false }
        return s.unicodeScalars.allSatisfy {
            ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
        }
    }
}
