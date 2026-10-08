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
    let paths = AppPaths.standard()
    let store: SettingsStore
    var settings = AppSettings.default
    var recording = true
    var menuBar: MenuBarController?
    var actions: AppActions?

    override init() {
        store = SettingsStore(file: AppPaths.standard().settings)
        super.init()
        settings = (try? store.load()) ?? .default
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? paths.ensureDirectories()

        // 动作表只构造一次：全局热键和菜单项共用同一份闭包。
        // 各建一份的话，"按热键"和"点菜单"迟早行为分叉。
        let acts = makeActions()
        actions = acts

        let controller = MenuBarController(
            state: { [weak self] in
                MenuBarController.State(settings: self?.settings ?? .default,
                                        recording: self?.recording ?? true,
                                        loginItemEnabled: false)
            },
            actions: acts)
        if controller.install() {
            menuBar = controller
        } else {
            log("状态栏图标安装失败\n")
        }
        let failed = registerHotkeys()
        if !failed.isEmpty && !Self.isProbeMode { reportFailures(failed) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let bar = self.menuBar else { return }
            if CommandLine.arguments.contains("--menu-preview") {
                bar.popUpPreviewMenu(at: NSPoint(x: 200, y: NSScreen.main!.frame.maxY - 120))
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApp.terminate(nil) }
                return
            }
            if CommandLine.arguments.contains("--hotkey-probe") {
                let failed = self.registerHotkeys()
                let bound = HotkeyID.allCases.map { id -> String in
                    id.rawValue + "=" + (HotkeyCenter.shared.boundCombo(for: id)?.displayString ?? "-")
                }.joined(separator: " ")
                log("HOTKEY_PROBE failed=[\(failed.map(\.rawValue).joined(separator: ","))] \(bound)\n")
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--menu-dump") {
                log(bar.dumpMenu())
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--menubar-probe") {
                log(bar.probeReport())
                NSApp.terminate(nil)
                return
            }
            // 图标被系统隐藏时必须说出来，否则用户以为 App 没启动。
            // 刘海 + 第三方图标占满时 install() 仍返回 true，只有 occlusionState 能看出来。
            if !bar.isStatusItemVisible, !CommandLine.arguments.contains("--no-gui") {
                log(bar.probeReport())
                let alert = NSAlert()
                alert.messageText = "Toolbox 的菜单栏图标没能显示"
                alert.informativeText = "这台 Mac 是刘海屏且菜单栏已被其它 App 占满，系统没有给 Toolbox 分配可见位置。\n"
                    + "功能不受影响，仍可用快捷键：⇧V 剪贴板 · ⌃A 截图 · ⌘, 打开设置\n"
                    + "想让图标出现，请到 系统设置 → 控制中心 收起不用的菜单栏项目。"
                alert.addButton(withTitle: "知道了")
                alert.addButton(withTitle: "打开设置")
                if alert.runModal() == .alertSecondButtonReturn { self.actions?.openSettings() }
            }
        }
    }

    /// 探针/演示模式下不弹模态框，否则会把自动化验证卡死在弹窗上。
    static let probeFlags = ["--menu-dump", "--menubar-probe", "--hotkey-probe",
                             "--menu-preview", "--panel-demo", "--panel-hold",
                             "--perms", "--smoke-hotkey"]
    static var isProbeMode: Bool { probeFlags.contains { CommandLine.arguments.contains($0) } }

    /// 注册全部热键。返回失败的 id 列表（空 = 全成功）。
    @discardableResult
    func registerHotkeys() -> [HotkeyID] {
        var failed: [HotkeyID] = []
        for id in HotkeyID.allCases {
            guard let combo = settings.hotkeys[id] else { failed.append(id); continue }
            let ok = HotkeyCenter.shared.register(id, combo) { [weak self] in
                self?.actions?.invoke(id)
            }
            if !ok { failed.append(id) }
        }
        return failed
    }

    /// 静默失败是最糟的失败：哪个键没注册上、被谁占了，必须说清楚。
    func reportFailures(_ failed: [HotkeyID]) {
        var lines: [String] = []
        for id in failed {
            guard let combo = settings.hotkeys[id] else {
                lines.append("\(id.rawValue)：设置里没有键位")
                continue
            }
            let st = HotkeyCenter.shared.probe(combo)
            let reason = st == noErr
                ? "内部冲突（同一键位被本 App 的另一个功能占用）"
                : "已被其它 App 抢注（Snipaste / SwitchHosts 等，Carbon 先注册者赢）"
            lines.append("\(combo.displayString)  \(id.rawValue) —— \(reason)")
        }
        let text = lines.joined(separator: "\n")
        log("HOTKEY FAILED:\n\(text)\n")
        guard !CommandLine.arguments.contains("--no-gui") else { return }
        let alert = NSAlert()
        alert.messageText = "有 \(failed.count) 个快捷键没能注册"
        alert.informativeText = text + "\n\n请到 Toolbox 设置 → 快捷键 换一组键位；"
            + "若提示\u{201c}已被其它 App 抢注\u{201d}，先退出占用它的那个 App。"
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn { actions?.openSettings() }
    }

    func makeActions() -> AppActions {
        AppActions(
            clipboard: {}, hostsQuick: {},
            captureRegion: { [weak self] in self?.showPlaceholder() },
            captureFull: {}, killAllPins: {},
            togglePause: { [weak self] in self?.recording.toggle() },
            openPermissions: {}, openSettings: { [weak self] in self?.showPlaceholder() },
            toggleLoginItem: {}, quit: { NSApp.terminate(nil) })
    }

    func showPlaceholder() {
        PanelPresenter.shared.show(content: PlaceholderPanelView(text: "M0 占位浮层"),
                                   anchor: .cursor, width: 320, height: 120) { _ in }
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
