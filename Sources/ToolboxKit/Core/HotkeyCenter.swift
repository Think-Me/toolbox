import Carbon.HIToolbox
import AppKit

private let kHotkeySignature: OSType = 0x544F4F42 // 'TOOB'

/// Carbon 事件回调。必须是 **non-capturing 的全局函数**，靠 refCon 找回实例。
/// 不能写成 `@convention(c) func` —— 该属性只能标注类型，标注声明会直接编译失败。
private func handleHotKey(_ next: EventHandlerCallRef?, _ event: EventRef?,
                          _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hk = EventHotKeyID()
    let st = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                               EventParamType(typeEventHotKeyID), nil,
                               MemoryLayout<EventHotKeyID>.size, nil, &hk)
    guard st == noErr else { return st }
    let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
    // Carbon 把热键事件投递到注册它的那个 runloop，也就是主线程；
    // 这里 assumeIsolated 是有事实依据的，不是用来消警告的。
    MainActor.assumeIsolated { center.dispatch(hk.id) }
    return noErr
}

public enum HotkeyID: String, Codable, CaseIterable, Sendable {
    case clipboard, hostsQuick, captureRegion, captureFull, killAllPins, openSettings
}

@MainActor
public final class HotkeyCenter {
    public static let shared = HotkeyCenter()

    private var registry = HotkeyRegistry()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var slots: [HotkeyID: UInt32] = [:]   // 业务 id → registry 内部 id
    private var callRef: EventHandlerCallRef?
    private var handlerInstalled = false

    public init() {}

    public enum Failure: Equatable {
        case invalidCombo
        case handlerNotInstalled
        case comboAlreadyBound
        case carbon(OSStatus)
    }
    public private(set) var lastError: Failure?

    func dispatch(_ id: UInt32) { registry.handler(for: id)?() }

    /// 键位显示串 → 供失败提示用（"⌃⌘A 已被占用"）。
    public func boundCombo(for id: HotkeyID) -> KeyCombo? {
        guard let assigned = slots[id] else { return nil }
        return registry.combo(for: assigned)
    }

    @discardableResult
    public func register(_ id: HotkeyID, _ combo: KeyCombo,
                         handler: @escaping @MainActor () -> Void) -> Bool {
        guard combo.isValidBinding else { lastError = .invalidCombo; return false }
        guard ensureHandlerInstalled() else { lastError = .handlerNotInstalled; return false }

        unregister(id)
        if let holder = registry.id(for: combo) { unregisterID(holder) }

        guard let assigned = registry.insert(combo, handler) else {
            lastError = .comboAlreadyBound; return false
        }
        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: kHotkeySignature, id: assigned)
        // keycode 参数是 UInt32，存储用 UInt16（对齐 NSEvent.keyCode）
        let st = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, hk,
                                     GetApplicationEventTarget(), 0, &ref)
        guard st == noErr, let ref else {
            registry.remove(assigned)
            lastError = .carbon(OSStatus(st))
            return false
        }
        refs[assigned] = ref
        slots[id] = assigned
        lastError = nil
        return true
    }

    public func unregister(_ id: HotkeyID) {
        guard let assigned = slots.removeValue(forKey: id) else { return }
        unregisterID(assigned)
    }

    private func unregisterID(_ assigned: UInt32) {
        if let ref = refs.removeValue(forKey: assigned) { UnregisterEventHotKey(ref) }
        registry.remove(assigned)
    }

    /// 试探注册再立刻注销：noErr = 空闲；`eventHotKeyExistsErr`(-9878) = 已被别的 App 占用。
    public func probe(_ combo: KeyCombo) -> OSStatus {
        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: kHotkeySignature, id: 0xFFFF_FFFE)
        let st = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, hk,
                                     GetApplicationEventTarget(), 0, &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return st
    }

    public static let alreadyTakenErr: OSStatus = OSStatus(-9878) // eventHotKeyExistsErr

    private func ensureHandlerInstalled() -> Bool {
        if handlerInstalled { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        let st = InstallEventHandler(GetApplicationEventTarget(), handleHotKey,
                                     1, &spec, refCon, &callRef)
        handlerInstalled = (st == noErr)
        return handlerInstalled
    }
}
