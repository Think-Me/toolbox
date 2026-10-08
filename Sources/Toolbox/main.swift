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

// 任务 9 的浮层自检。两种模式：
//   --panel-demo  连开连关 5 次，校验"一次 show 恰好一次 dismiss"与 monitor 不泄漏
//   --panel-hold  把面板挂在屏上 20 秒，供外部用 CGWindowList 按 PID 验窗口真的上屏
// 关键：所有窗口操作必须在 applicationDidFinishLaunching 之后做。
// 在 app.run() 之前 orderFront，面板不会真正上屏（实测 CGWindowList 查不到窗口）。
final class CountBox { var n = 0 }

@MainActor
final class PanelDemoDelegate: NSObject, NSApplicationDelegate {
    let hold: Bool
    init(hold: Bool) { self.hold = hold }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if hold {
            PanelPresenter.shared.show(content: PlaceholderPanelView(text: "panel-hold"),
                                       anchor: .cursor, width: 320, height: 120) { _ in }
            log("frontApp=\(PanelPresenter.shared.frontAppBeforePresentation?.localizedName ?? "nil") appActive=\(NSApp.isActive) pid=\(ProcessInfo.processInfo.processIdentifier)\n")
            log("screens=\(NSScreen.screens.count) main=\(String(describing: NSScreen.main?.frame)) cursor=\(NSEvent.mouseLocation)\n")
            if let win = NSApp.windows.first(where: { $0 is FloatingPanel }) as? FloatingPanel {
                log("MYWINNUM=\(win.windowNumber)\n")
                log("panel isVisible=\(win.isVisible) onActiveSpace=\(win.isOnActiveSpace) frame=\(win.frame) alpha=\(win.alphaValue) level=\(win.level.rawValue) shares=\(win.sharingType.rawValue)\n")
            } else {
                log("panel NOT in NSApp.windows; all=\(NSApp.windows.map { String(describing: type(of: $0)) })\n")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { NSApp.terminate(nil) }
            return
        }
        let box = CountBox()
        var cycles = 0
        func step() {
            PanelPresenter.shared.show(content: PlaceholderPanelView(text: "M0 占位浮层"),
                                       anchor: .cursor, width: 320, height: 120) { _ in
                box.n += 1
                cycles += 1
                if cycles < 5 { DispatchQueue.main.async { step() } }
                else {
                    log("PANEL_OK cycles=\(cycles) dismisses=\(box.n) showing=\(PanelPresenter.shared.isShowing)\n")
                    NSApp.terminate(nil)
                }
            }
            PanelPresenter.shared.dismissCurrent(reason: .explicitClose)
        }
        step()
    }
}

func log(_ s: String) {
    FileHandle.standardError.write(s.data(using: .utf8)!)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        FileHandle.standardError.write("Toolbox up (M0 骨架)\n".data(using: .utf8)!)
    }
}

let app = NSApplication.shared
// NSApplication.delegate 是**弱引用**：delegate 必须放在有生命周期的存储里，
// 直接 `app.delegate = Foo()` 会在下一行就被 ARC 回收，表现为"回调从来不触发"。
if CommandLine.arguments.contains("--panel-demo") || CommandLine.arguments.contains("--panel-hold") {
    let demoDelegate = PanelDemoDelegate(hold: CommandLine.arguments.contains("--panel-hold"))
    app.delegate = demoDelegate
    app.run()
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
