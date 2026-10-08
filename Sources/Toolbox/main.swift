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
        if !AppDelegate.earlyRegular { NSApp.setActivationPolicy(.accessory) }
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
    var recording = true
    var menuBar: MenuBarController?
    var actions: AppActions?
    var settingsWindow: SettingsWindowController?
    /// 设置的唯一来源。AppDelegate 里再存一份 settings 会在"录制改键 → 菜单/热键读哪份"上分叉。
    let model: AppModel

    override init() {
        store = SettingsStore(file: AppPaths.standard().settings)
        model = AppModel(
            settings: (try? store.load()) ?? .default,
            store: store,
            permissions: PermissionCenter(probes: .live),
            loginItem: LoginItemCoordinator(manager: SMLoginItemManager()))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !Self.earlyRegular { NSApp.setActivationPolicy(.accessory) }
        try? paths.ensureDirectories()

        // 动作表只构造一次：全局热键和菜单项共用同一份闭包。
        // 各建一份的话，"按热键"和"点菜单"迟早行为分叉。
        let acts = makeActions()
        actions = acts

        let controller = MenuBarController(
            state: { [weak self] in
                MenuBarController.State(settings: self?.model.settings ?? .default,
                                        recording: self?.recording ?? true,
                                        loginItemEnabled: self?.model.loginItemEnabled ?? false)
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
            if CommandLine.arguments.contains("--grant-screen") {
                // 一步做完两件事：触发系统授权弹窗 + 打开对应设置面板。
                // 屏幕录制授权后必须重启 App 才生效，这点在输出里说清楚。
                self.model.permissions.requestScreenRecording()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
                log("已发起屏幕录制授权：请在弹出的对话框选\u{201c}打开系统设置\u{201d}，"
                    + "或直接在刚打开的面板里把 Toolbox 的开关打开，然后完全退出 App 再重开。\n")
                return
            }
            if CommandLine.arguments.contains("--settings-preview") {
                self.showSettings()
                if let w = self.settingsWindow?.window {
                    log("SETTINGS \(self.settingsWindow!.probeLine)\n")
                    log("RESPONDER 类型=\(String(describing: w.firstResponder))\n")
                    let f = w.frame
                    let main = NSScreen.main?.frame.height ?? 0
                    log("SETTINGS_WIN frame=\(f) 顶部Y=\(main - f.maxY) title=\(w.title) "
                        + "key=\(w.isKeyWindow) visible=\(w.isVisible) 子视图=\(String(describing: w.contentView?.subviews.count))\n")
                }
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
                             "--perms", "--smoke-hotkey", "--settings-preview",
                             "--grant-screen"]
    /// 实验：策略在 finishLaunching 之后再改可能完不成激活握手，
    /// 所以 --regular-mode 在 app.run() 之前就把策略定成 .regular。
    static var earlyRegular: Bool { CommandLine.arguments.contains("--regular-mode") }

    static var isProbeMode: Bool { probeFlags.contains { CommandLine.arguments.contains($0) } }

    /// 改键后重新注册：先全部注销再按新值注册，避免残留旧键位仍在吞事件。
    func reregisterHotkeys() {
        for id in HotkeyID.allCases { HotkeyCenter.shared.unregister(id) }
        let failed = registerHotkeys()
        if !failed.isEmpty { reportFailures(failed) }
    }

    /// 注册全部热键。返回失败的 id 列表（空 = 全成功）。
    @discardableResult
    func registerHotkeys() -> [HotkeyID] {
        var failed: [HotkeyID] = []
        for id in HotkeyID.allCases {
            guard let combo = model.settings.hotkeys[id] else { failed.append(id); continue }
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
            guard let combo = model.settings.hotkeys[id] else {
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
        model.onHotkeysChanged = { [weak self] _ in self?.reregisterHotkeys() }
        return AppActions(
            clipboard: {}, hostsQuick: {},
            captureRegion: { [weak self] in self?.showPlaceholder() },
            captureFull: {}, killAllPins: {},
            togglePause: { [weak self] in self?.recording.toggle() },
            openPermissions: { [weak self] in self?.showSettings() },
            openSettings: { [weak self] in self?.showSettings() },
            toggleLoginItem: { [weak self] in self?.model.toggleLoginItem() },
            quit: { NSApp.terminate(nil) })
    }

    func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(model: model) }
        settingsWindow?.show()
    }

    func showPlaceholder() {
        PanelPresenter.shared.show(content: PlaceholderPanelView(text: "M0 占位浮层"),
                                   anchor: .cursor, width: 320, height: 120) { _ in }
    }
}

let app = NSApplication.shared
if AppDelegate.earlyRegular { app.setActivationPolicy(.regular) }
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
