import Foundation

/// 版本号比较。xray 用 `v26.3.27`、规则库用日期式 `202510010040`，
/// 都不是能直接字符串比的语义版本，得拆成数字段逐个比。
public enum ProxyVersion {
    /// "v26.3.27" → [26,3,27]；非数字前缀忽略，取所有数字段
    public static func components(_ s: String) -> [Int] {
        s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    /// candidate 是否严格比 current 新。缺 current 视为需要更新。
    public static func isNewer(_ candidate: String?, than current: String?) -> Bool {
        guard let candidate, !candidate.isEmpty else { return false }
        guard let current, !current.isEmpty else { return true }
        let a = components(candidate), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
