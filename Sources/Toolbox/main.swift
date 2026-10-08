import AppKit
import ToolboxKit

// 任务 5 的端到端冒烟入口。任务 11 收尾时整段删除。
// 本地类可以正常当 NSApplicationDelegate（实测 applicationDidFinishLaunching: 照常回调），
// 但绝不许把这段抽进普通 func —— 非 @MainActor 函数里访问 NSApplication.shared 会触发
// Swift 6 的 main-actor 隔离警告。main.swift 顶层代码本身是 MainActor 隔离的。
if CommandLine.arguments.contains("--smoke-hotkey") {
    let app = NSApplication.shared

    final class Smoke: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) {
            NSApp.setActivationPolicy(.accessory)
            let combo = KeyCombo(keyCode: KeyCombo.ansiA,
                                 carbonModifiers: KeyCombo.control | KeyCombo.cmd)
            let ok = HotkeyCenter.shared.register(.captureRegion, combo) {
                FileHandle.standardError.write("FIRED\n".data(using: .utf8)!)
                NSApp.terminate(nil)
            }
            FileHandle.standardError.write("register=\(ok)\n".data(using: .utf8)!)
            if !ok { NSApp.terminate(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { NSApp.terminate(nil) }
        }
    }

    let smoke = Smoke()
    app.delegate = smoke
    app.run()
}

// 权限自检：打印四项探针的真实值，用于和 shell 侧独立探测对账。
if CommandLine.arguments.contains("--perms") {
    let rows = PermissionCenter(probes: .live).snapshot()
    for r in rows {
        FileHandle.standardError.write("\(r.permission.rawValue): \(r.state)\n".data(using: .utf8)!)
    }
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        FileHandle.standardError.write("Toolbox up (M0 骨架)\n".data(using: .utf8)!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
