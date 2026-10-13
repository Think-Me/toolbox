import Foundation

/// 快捷键冲突判定。
///
/// 做成纯函数（探测用闭包注入）的原因是"撞了没有"必须能单测，而且 Carbon 的
/// probe **有副作用**（临时注册再注销），并有个陷阱：对"自己当前正持有这个键位"
/// 必然返回"被占用"。不加区分地调用，会把"重新录成同一个键位"也误判成冲突。
public enum HotkeyConflict {

    /// - Parameters:
    ///   - proposed: 正在录制的新键位
    ///   - id: 正在录制哪一行
    ///   - bindings: 当前全部键位设置
    ///   - probeOccupied: 系统级探测。只在前两步都没命中时才被调用 ——
    ///     自己人冲突先报，能省一次 Carbon 调用，也让纯函数测试不必碰 Carbon
    /// - Returns: 冲突理由（可直接显示给用户），nil = 可以用
    public static func detect(proposed: KeyCombo,
                              for id: HotkeyID,
                              bindings: [HotkeyID: KeyCombo],
                              probeOccupied: ((KeyCombo) -> Bool)? = nil) -> String? {
        // 1) 本 App 内部：同一个键位被另一个功能占了
        if let other = bindings.first(where: { $0.key != id && $0.value == proposed })?.key {
            return "「\(proposed.displayString)」已分配给「\(other.label)」，请换一个键位"
        }
        // 2) 重选成当前这一行的键位：不是冲突。
        //    而且**绝不能去探测** —— 那个键位正由我们自己持有，probe 必返回占用
        if bindings[id] == proposed { return nil }
        // 3) 系统级：别的 App 抢先注册了
        if probeOccupied?(proposed) == true {
            return "「\(proposed.displayString)」已被其他 App 占用"
                + "（Snipaste / SwitchHosts 等，Carbon 先注册者赢），"
                + "换一个键位或先退出对方"
        }
        return nil
    }
}
