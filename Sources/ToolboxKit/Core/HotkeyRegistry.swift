/// 纯逻辑：热键的 id 分配、combo→id 反查、注销释放。
/// 刻意不碰 Carbon，这样这部分能单测，Carbon 调用隔离在 HotkeyCenter。
///
/// 不标 Sendable：Entry 持有 @MainActor 闭包，标了会编译失败。
/// 它只在 @MainActor 的 HotkeyCenter 内部使用。
public struct HotkeyRegistry {
    public struct Entry {
        public let combo: KeyCombo
        public let id: UInt32
        public var handler: @MainActor () -> Void
    }

    private var entries: [UInt32: Entry] = [:]
    private var nextID: UInt32 = 1

    public init() {}

    public var count: Int { entries.count }

    /// 返回 nil 表示该 combo 已被占用。
    @discardableResult
    public mutating func insert(_ combo: KeyCombo,
                                _ handler: @escaping @MainActor () -> Void = {}) -> UInt32? {
        guard !entries.values.contains(where: { $0.combo == combo }) else { return nil }
        let id = nextID
        nextID += 1
        entries[id] = Entry(combo: combo, id: id, handler: handler)
        return id
    }

    public mutating func remove(_ id: UInt32) { entries[id] = nil }

    public func handler(for id: UInt32) -> (@MainActor () -> Void)? { entries[id]?.handler }
    public func combo(for id: UInt32) -> KeyCombo? { entries[id]?.combo }

    /// 反查：某个键位当前被哪个内部 id 占着。
    public func id(for combo: KeyCombo) -> UInt32? {
        entries.first { $0.value.combo == combo }?.key
    }
}
