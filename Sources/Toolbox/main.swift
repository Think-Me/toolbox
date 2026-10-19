import AppKit
import STTextView
import ToolboxKit

/// 顶层 `let` 在 main.swift 里是**按语句顺序初始化**的，不是懒加载：
/// 所以 app 必须声明在所有使用它的顶层分支之前。之前它被删到只剩底部一份，
/// 上面的 --smoke-hotkey 分支就引用了未初始化的全局变量，表现为
/// "进程活着但 delegate 回调一次都不触发"（make smoke 静默失败就是这么来的）。
let app = NSApplication.shared

/// 探针用的假 DNS：真的 DNS 刷新由 --hosts-e2e 单独验
struct FakeDns: DnsFlushing {
    func flush() -> DnsFlushOutcome { .ok }
}

// 任务 5 的端到端冒烟入口。任务 11 收尾时整段删除。
// 本地类可以正常当 NSApplicationDelegate（实测 applicationDidFinishLaunching: 照常回调），
// 但绝不许把这段抽进普通 func —— 非 @MainActor 函数里访问 NSApplication.shared 会触发
// Swift 6 的 main-actor 隔离警告。main.swift 顶层代码本身是 MainActor 隔离的。
if CommandLine.arguments.contains("--smoke-hotkey") {

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
    var updateTimer: Timer?
    var actions: AppActions?
    var settingsWindow: SettingsWindowController?
    /// 贴图总管是单例，但方向/上下限这些参数要从入口注入
    private var pinsOfCapture: PinManager { .shared }
    /// 设置的唯一来源。AppDelegate 里再存一份 settings 会在"录制改键 → 菜单/热键读哪份"上分叉。
    let model: AppModel

    // MARK: 剪贴板模块
    lazy var database = Database(url: paths.database.appendingPathExtension("db"))
    lazy var media = MediaStore(directory: paths.mediaDirectory)
    lazy var clipboardStore = ClipboardStore(db: database, media: media)
    /// 粘贴与采集共享同一个追踪器：目标 App 回写 pasteboard 会丢掉自写标记，
    /// 只能靠这个时间窗避免把自己粘出去的内容再采一遍（实测曾让计数 +3）。
    lazy var selfWrites = SelfWriteTracker()
    lazy var pasteSimulator = PasteSimulator(
        driver: SystemPasteDriver(),
        imageLoader: { [media] sha in try? media.data(sha: sha) },
        tracker: selfWrites)
    lazy var clipboardPanel = ClipboardPanelController(
        store: clipboardStore, media: media, simulator: pasteSimulator,
        settings: { [weak self] in self?.model.settings ?? .default })
    lazy var captureFlow = CaptureFlow(settings: { [weak self] in self?.model.settings ?? .default })

    // MARK: Hosts 模块
    lazy var hostsStore = HostsStore(file: paths.hostsRules)
    lazy var hostsApplying = HostsApplying(
        writer: DirectHostsWriter(path: "/etc/hosts",
                                  backupDirectory: paths.hostsBackupDirectory,
                                  originalSnapshot: paths.hostsOriginal))
    lazy var hostsModel = HostsViewModel(store: hostsStore, applying: hostsApplying)

    // MARK: 代理模块（M5）
    lazy var proxyModel = ProxyViewModel(paths: paths)
    var hostsPanel: HostsQuickPanelView?

    var hostsSnapshot: HostsMenuSnapshot {
        HostsMenuSnapshot(managementOn: hostsModel.library.managementOn,
                          rows: hostsModel.library.groups.flatMap { g in
                              g.rules.map { HostsMenuRow(id: $0.id, group: g.name, name: $0.name,
                                                         enabled: $0.enabled) }
                          })
    }
    lazy var monitor = ClipboardMonitor(
        store: clipboardStore, media: media, inputs: .live(),
        settings: { [weak self] in self?.model.settings ?? .default },
        selfWrites: selfWrites)

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
        // accessory App 没有菜单条，但 ⌘C/⌘V/⌘Z/⌘A 这类 key equivalent 是走
        // **主菜单**匹配的。不装 Edit 菜单，文本视图里就"能打字、不能粘贴"。
        // （上一版这行被误插进 PanelDemoDelegate 的同名方法里，等于没装：
        //  实测 NSApp.mainMenu == nil）
        MainMenu.install()
        try? paths.ensureDirectories()

        // 动作表只构造一次：全局热键和菜单项共用同一份闭包。
        // 各建一份的话，"按热键"和"点菜单"迟早行为分叉。
        let acts = makeActions()
        actions = acts

        let controller = MenuBarController(
            state: { [weak self] in
                MenuBarController.State(settings: self?.model.settings ?? .default,
                                        recording: self?.recording ?? true,
                                        loginItemEnabled: self?.model.loginItemEnabled ?? false,
                                        hosts: self?.hostsSnapshot ?? .empty)
            },
            actions: acts)
        if controller.install() {
            menuBar = controller
        } else {
            log("状态栏图标安装失败\n")
        }
        let failed = registerHotkeys()
        if !failed.isEmpty && !Self.isProbeMode { reportFailures(failed) }
        startClipboard()
        startUpdateChecks()

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
            if CommandLine.arguments.contains("--overlay-preview") {
                // 不依赖全局热键直接呼出截图遮罩：
                // 自动化环境里 RustDesk 等会独占键盘，热键测不了时用这个
                captureFlow.onMessage = { text in DegradeNotice.shared.show(text) }
                captureFlow.startRegionCapture()
                return
            }
            if CommandLine.arguments.contains("--text-probe") {
                // 文字工具端到端验证：只预置选区 + 选中文字工具，
                // 之后由 Scripts/cg-click / cg-type 合成真实点击与输入
                captureFlow.onMessage = { text in DegradeNotice.shared.show(text) }
                captureFlow.overlayProbe = { view in
                    view.magnifierEnabled = false
                    view.applyForProbe([
                        .selectWindow(CGRect(x: 180, y: 140, width: 560, height: 400)),
                        .toolChanged(.text),
                    ])
                }
                if let main = NSScreen.screens.first {
                    CGWarpMouseCursorPosition(CGPoint(x: main.frame.midX, y: main.frame.midY))
                    CGAssociateMouseAndMouseCursorPosition(1)
                }
                captureFlow.startRegionCapture()
                return
            }
            if CommandLine.arguments.contains("--annotation-preview") {
                // 截图标注的可视化核对：预置选区 + 五种工具的各一个图形。
                // 自动化环境里点不了遮罩（合成键被 Secure Input 丢弃），所以靠它看效果。
                captureFlow.onMessage = { text in DegradeNotice.shared.show(text) }
                captureFlow.overlayProbe = { view in
                    // 放大镜会挡住要看的东西，探针里关掉
                    view.magnifierEnabled = false
                    _ = 0
                    view.applyForProbe([
                        .selectWindow(CGRect(x: 180, y: 140, width: 560, height: 400)),
                        .toolChanged(.rect),
                        .annotationDown(CGPoint(x: 200, y: 160)),
                        .annotationDragged(CGPoint(x: 320, y: 230)),
                        .annotationUp,
                        // 马赛克压在**一行字**上：该不该生效，看字还认不认得
                        .toolChanged(.mosaic),
                        .annotationDown(CGPoint(x: 200, y: 150)),
                        .annotationDragged(CGPoint(x: 560, y: 176)),
                        .annotationUp,
                        .toolChanged(.arrow),
                        .annotationDown(CGPoint(x: 400, y: 265)),
                        .annotationDragged(CGPoint(x: 600, y: 345)),
                        .annotationUp,
                        .toolChanged(.pen),
                        .annotationDown(CGPoint(x: 200, y: 285)),
                        .annotationDragged(CGPoint(x: 230, y: 250)),
                        .annotationDragged(CGPoint(x: 260, y: 305)),
                        .annotationDragged(CGPoint(x: 290, y: 250)),
                        .annotationDragged(CGPoint(x: 320, y: 305)),
                        .annotationUp,
                        .toolChanged(.text),
                        .annotationDown(CGPoint(x: 200, y: 360)),
                        .annotationUp,
                        .commitText("标注文字 ABC", fontSize: 26, editing: nil),
                        .toolChanged(nil),
                    ])
                    let a = view.state.annotation
                    FileHandle.standardError.write(
                        ("ANNPROBE count=\(a.annotations.count) canUndo=\(a.canUndo) "
                         + "canRedo=\(a.canRedo) tool=\(String(describing: a.tool))\n")
                            .data(using: .utf8)!)
                }
                // 遮罩跟着光标走（captureUnderCursor），外接屏在位时鼠标常常在
                // 另一块屏上，截图核对就会拍到空屏。先把光标拉回主屏。
                if let main = NSScreen.screens.first {
                    let p = CGPoint(x: main.frame.midX, y: main.frame.midY)
                    CGWarpMouseCursorPosition(p)
                    CGAssociateMouseAndMouseCursorPosition(1)
                }
                captureFlow.startRegionCapture()
                return
            }
            if CommandLine.arguments.contains("--clip-preview") {
                clipboardPanel.show()
                return
            }
            if CommandLine.arguments.contains("--paste-probe") {
                // 走和 ⌘V 完全相同的路径：NSApp.sendAction 沿 key window 的
                // responder chain 找 paste:。不需要真键盘，因此能在自动化里验证。
                let tv = STTextView()
                tv.isEditable = true
                tv.text = "起始内容 "
                let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 200),
                                 styleMask: [.titled], backing: .buffered, defer: false)
                w.contentView = tv
                w.makeKeyAndOrderFront(nil)
                w.makeFirstResponder(tv)
                NSApp.activate(ignoringOtherApps: true)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("10.0.0.7 pasted.local", forType: .string)
                let viaChain = NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                let afterChain = tv.text ?? "?"
                // 对照：直接指定 target，绕开 key window / responder chain
                tv.text = "起始内容 "
                let viaTarget = NSApp.sendAction(#selector(NSText.paste(_:)), to: tv, from: nil)
                let afterTarget = tv.text ?? "?"
                log("PASTEPROBE 走响应链 sent=\(viaChain) 文本=\(afterChain)\n")
                log("PASTEPROBE 指定target sent=\(viaTarget) 文本=\(afterTarget)\n")
                log("PASTEPROBE keyWindow=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil") "
                    + "本窗isKey=\(w.isKeyWindow) firstResponder=\(String(describing: w.firstResponder))\n")
                log("PASTEPROBE 结论=\(afterTarget.contains("pasted.local") ? "paste: 本身可用；响应链取決于窗口是否 key" : "paste: 根本不可用")\n")
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--menu-probe") {
                // 粘贴问题的取证：主菜单到底装没装、Paste 项能不能被校验通过
                guard let main = NSApp.mainMenu else {
                    log("MENUPROBE mainMenu=nil\n"); NSApp.terminate(nil); return
                }
                log("MENUPROBE topItems=\(main.items.count) autoenables=\(main.autoenablesItems)\n")
                for (i, top) in main.items.enumerated() {
                    let subs = (top.submenu?.items ?? []).map { it in
                        "\(it.title)[\(it.action.map(NSStringFromSelector) ?? "-")/\(it.keyEquivalent)]"
                    }.joined(separator: " ")
                    log("MENUPROBE [\(i)] '\(top.title)' autoenables=\(top.submenu?.autoenablesItems.description ?? "-") → \(subs)\n")
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("probe text", forType: .string)
                let edit = main.items.compactMap(\.submenu).first { $0.title == "编辑" }
                if let paste = edit?.items.first(where: { $0.action == #selector(NSText.paste(_:)) }) {
                    log("MENUPROBE pasteItem.isEnabled=\(paste.isEnabled) (autoenables 会覆盖它)\n")
                }
                // 图片型剪贴板：STTextView 的 paste 校验要求 string(forType:) != nil，
                // 剪贴板里只有图时 Paste 项会被它自己禁用
                pb.clearContents()
                pb.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
                log("MENUPROBE 图片剪贴板时 string(forType:.string)=\(pb.string(forType: .string) ?? "nil")\n")
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--hosts-vm-probe") {
                Task { @MainActor in
                // ViewModel → HostsApplying → DirectHostsWriter 全链路，
                // 但 hosts 指向临时文件：不碰真 /etc/hosts（那条已由 --hosts-e2e 单独验过）
                let dir = URL(fileURLWithPath: "/tmp/toolbox-vmprobe-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let fakeHosts = dir.appendingPathComponent("hosts")
                try? "127.0.0.1 localhost\n::1 localhost\n".write(to: fakeHosts, atomically: true,
                                                                    encoding: .utf8)
                let writer = DirectHostsWriter(path: fakeHosts.path,
                                               backupDirectory: dir.appendingPathComponent("backup"),
                                               originalSnapshot: dir.appendingPathComponent("original"))
                let store = HostsStore(file: dir.appendingPathComponent("rules.json"))
                let vm = HostsViewModel(store: store, applying: HostsApplying(writer: writer,
                                                                              dns: FakeDns()))
                let rule = Rule(name: "内网", kind: .inline(content: "10.0.0.1 intranet.local\n"))
                vm.library = HostsLibrary(groups: [RuleGroup(name: "公司", rules: [rule])])
                log("VMPROBE initial enabled=\(vm.library.enabledRules.count)\n")
                await vm.toggle(rule.id)
                let after = (try? String(contentsOf: fakeHosts, encoding: .utf8)) ?? "?"
                log("VMPROBE status=\(vm.statusMessage ?? "nil")\n")
                log("VMPROBE hostsContent=\(after.replacingOccurrences(of: "\n", with: "|"))\n")
                await vm.toggle(rule.id)
                let off = (try? String(contentsOf: fakeHosts, encoding: .utf8)) ?? "?"
                log("VMPROBE afterOff=\(off.replacingOccurrences(of: "\n", with: "|"))\n")
                log("VMPROBE rulesJsonSaved=\(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rules.json").path))\n")
                try? FileManager.default.removeItem(at: dir)
                NSApp.terminate(nil)
                }
                return
            }
            if CommandLine.arguments.contains("--hosts-e2e") {
                // 拿真 /etc/hosts 做完整往返：写一条测试规则 → 查解析是否生效 → 还原 → 比对字节。
                // 这一步是 M4 验收的核心，也是唯一能证明"提权 + in-place 写 + 哨兵块模型"
                // 三者真的协同工作的办法。
                let paths = AppPaths.standard()
                let writer = DirectHostsWriter(
                    path: "/etc/hosts",
                    backupDirectory: paths.hostsBackupDirectory,
                    originalSnapshot: paths.hostsOriginal)
                func inode(_ p: String) -> UInt64? {
                    var st = stat()
                    return lstat(p, &st) == 0 ? UInt64(st.st_ino) : nil
                }
                do {
                    let original = try writer.read()
                    let inoBefore = inode("/etc/hosts")
                    log("E2E original_bytes=\(original.utf8.count) inode=\(String(describing: inoBefore))\n")
                    let compiled = try RuleCompiler.compile(
                        enabled: [NamedRule(name: "toolbox-e2e",
                                            content: "127.0.0.1 example.toolbox-e2e.test")],
                        currentHosts: original).get()
                    try writer.write(compiled.content)
                    let after = try writer.read()
                    let inoAfter = inode("/etc/hosts")
                    log("E2E wrote_bytes=\(after.utf8.count) inodeSame=\(inoBefore == inoAfter) "
                        + "blockPresent=\(after.contains("example.toolbox-e2e.test")) "
                        + "userLinesKept=\(after.contains("localhost"))\n")
                    // 真的刷 DNS 并查解析：证明"写了确实生效"，而不是只改了文件
                    let flush = DnsFlusher().flush()
                    log("E2E dnsFlush=\(flush)\n")
                    let q = Process()
                    q.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
                    q.arguments = ["-q", "host", "-a", "name", "example.toolbox-e2e.test"]
                    let pipe = Pipe(); q.standardOutput = pipe; q.standardError = pipe
                    try? q.run(); q.waitUntilExit()
                    let resolved = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                                          as: UTF8.self)
                    log("E2E resolve=\(resolved.replacingOccurrences(of: "\n", with: "|"))\n")
                    // 规则关掉 = 摘掉托管块
                    let cleaned = try RuleCompiler.compile(enabled: [], currentHosts: after).get()
                    try writer.write(cleaned.content)
                    let restored = try writer.read()
                    // 只多了结尾一个换行：原文件本来就没有换行，而 hosts 应该以换行结尾
                    log("E2E blockGone=\(!restored.contains("toolbox-e2e")) "
                        + "restoredBytes=\(restored.utf8.count) originalBytes=\(original.utf8.count) "
                        + "onlyDiffIsTrailingNewline=\(restored == original + "\n")\n")

                    // restoreOriginal 走的是原样写回，必须字节级一致
                    try writer.restoreOriginal()
                    let exact = try writer.read()
                    log("E2E restoreOriginal_identical=\(exact == original) "
                        + "bytes=\(exact.utf8.count)\n")
                } catch {
                    log("E2E FAIL \(error)\n")
                }
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--pin-demo") {
                let cs = CGColorSpaceCreateDeviceRGB()
                let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setFillColor(CGColor(colorSpace: cs, components: [0.85, 0.2, 0.25, 1])!)
                ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
                ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
                ctx.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
                let cg = ctx.makeImage()!
                let img = NSImage(cgImage: cg, size: NSSize(width: 300, height: 200))
                PinManager.shared.settingsProvider = { [weak self] in self?.model.settings ?? .default }
                PinManager.shared.magnifySignProvider = { [weak self] in
                    (self?.model.settings.scrollZoomDirection ?? .upMagnifies) == .downMagnifies ? -1 : 1
                }
                let win = PinManager.shared.pin(img, at: CGRect(x: 500, y: 500, width: 300, height: 200))
                log("PIN_DEMO id=\(win.id.uuidString.prefix(8)) frame=\(win.frame) "
                    + "count=\(PinManager.shared.pinCount)\n")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    log("PIN_STATE isVisible=\(win.isVisible) onActiveSpace=\(win.isOnActiveSpace) "
                        + "alpha=\(win.alphaValue) level=\(win.level.rawValue) "
                        + "hasShadow=\(win.hasShadow) bg=\(win.backgroundColor as Any) "
                        + "contentView=\(String(describing: win.contentView?.frame)) "
                        + "appWindows=\(NSApp.windows.count) hidden=\(NSApp.isHidden)\n")
                }
                return
            }
            if CommandLine.arguments.contains("--capture-probe") {
                Task { @MainActor in
                    do {
                        let frame = try await CaptureService().captureUnderCursor()
                        let rep = NSBitmapImageRep(cgImage: frame.image)
                        let png = rep.representation(using: .png, properties: [:]) ?? Data()
                        let out = URL(fileURLWithPath: "/tmp/toolbox-capture-probe.png")
                        try png.write(to: out)
                        log("CAPTURE_OK px=\(frame.image.width)x\(frame.image.height) "
                            + "points=\(frame.screenFrameInPoints) scale=\(frame.scale) "
                            + "bytes=\(png.count) -> \(out.path)\n")
                        log("CAPTURE_STATS \(Self.pixelStats(frame.image))\n")
                    } catch {
                        log("CAPTURE_FAIL \(error)\n")
                    }
                    NSApp.terminate(nil)
                }
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
            if CommandLine.arguments.contains("--proxy-run-probe") {
                // 端到端：真实内置内核走 bootstrap→编译→启动，验证端口真在 listen
                let vm = proxyModel
                vm.setPorts(socks: 20808, http: 20809)
                let json: [String: Any] = ["ps": "probe", "add": "127.0.0.1", "port": "443",
                    "id": "11111111-2222-3333-4444-555555555555", "aid": "0", "net": "tcp"]
                let b64 = (try? JSONSerialization.data(withJSONObject: json))?.base64EncodedString() ?? ""
                vm.addField = "vmess://" + b64
                vm.addFromLink()
                vm.startEngine()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    let socksUp = ProcessProxyRunner().run("/usr/bin/nc", ["-z", "127.0.0.1", "20808"]).status == 0
                    let httpUp = ProcessProxyRunner().run("/usr/bin/nc", ["-z", "127.0.0.1", "20809"]).status == 0
                    log("PROXYRUN state=\(vm.engineState) socksListen=\(socksUp) httpListen=\(httpUp) nodes=\(vm.library.nodes.count)\n")
                    vm.shutdown()
                    NSApp.terminate(nil)
                }
                return
            }
            if CommandLine.arguments.contains("--rules-update-probe") {
                // 真实跑一遍规则库更新（直连），确认进度回调 + 文件替换 + 版本戳
                Task { @MainActor in
                    final class P: @unchecked Sendable { var ticks = 0; var last = -1.0 }
                    let p = P()
                    let info = await UpdateService.check(paths: AppPaths.standard(), fetcher: URLSessionFetcher())
                    guard let tag = info.rulesLatest else { log("RULESUPD 拿不到最新版本\n"); NSApp.terminate(nil); return }
                    let r = await UpdateService.applyRulesUpdate(tag: tag, paths: AppPaths.standard(),
                                                                 fetcher: URLSessionFetcher()) { prog in
                        p.ticks += 1; p.last = prog
                    }
                    let geo = ((try? Data(contentsOf: AppPaths.standard().proxyDirectory.appendingPathComponent("geoip.dat")))?.count) ?? 0
                    let stamp = (try? String(contentsOf: AppPaths.standard().proxyDirectory.appendingPathComponent("rules-version"), encoding: .utf8)) ?? "?"
                    switch r {
                    case .success: log("RULESUPD ok tag=\(tag) 进度回调次数=\(p.ticks) 末次=\(p.last) geoip字节=\(geo) 戳=\(stamp)\n")
                    case .failure(let e): log("RULESUPD 失败 \(e)\n")
                    }
                    NSApp.terminate(nil)
                }
                return
            }
            if CommandLine.arguments.contains("--update-run-probe") {
                // 验证 delegate 下载 + 进度回调这条真实路径（下个小 JSON，直连）
                Task { @MainActor in
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("updprobe-\(UUID().uuidString).json")
                    final class Prog: @unchecked Sendable { var last = -1.0 }
                    let prog = Prog()
                    let f = URLSessionFetcher()
                    do {
                        try await f.download(UpdateEndpoints.xrayAPI, to: tmp) { p in prog.last = p }
                        let size = (try? Data(contentsOf: tmp).count) ?? 0
                        let tag = UpdateService.tag(fromReleaseJSON: (try? Data(contentsOf: tmp)) ?? Data()) ?? "?"
                        log("UPDPROBE ok 末次进度=\(prog.last) bytes=\(size) tag=\(tag)\n")
                    } catch { log("UPDPROBE 失败 \(error)\n") }
                    try? FileManager.default.removeItem(at: tmp)
                    NSApp.terminate(nil)
                }
                return
            }
            if CommandLine.arguments.contains("--app-update-probe") {
                // 实测：查更新 + 下载最新 dmg + 挂载验证（不做替换，避免覆盖 dev app）
                Task { @MainActor in
                    let cur = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
                    let fetcher = URLSessionFetcher(proxyPort: 10809)
                    let st = UpdateSettings(useProxy: true, proxyPort: 10809)
                    let status = await AppUpdater.check(currentVersion: cur, settings: st, fetcher: fetcher)
                    log("UPDCHECK cur=\(cur) → \(status)\n")
                    if let data = try? await fetcher.get(URL(string: AppUpdater.latestAPI)!),
                       let info = AppUpdater.parseRelease(data) {
                        log("UPDINFO tag=\(info.tag) dmg=\(info.dmgURL)\n")
                        do {
                            let (dmg, mount) = try await AppUpdater.downloadAndMount(info: info, settings: st, fetcher: fetcher)
                            let sz = ((try? Data(contentsOf: dmg))?.count) ?? 0
                            let hasApp = AppUpdater.appInMount(mount) != nil
                            log("UPDDL dmg字节=\(sz) 挂载含Toolbox.app=\(hasApp)\n")
                            _ = AppUpdater.detach(mount)
                        } catch { log("UPDDDL 失败 \(error)\n") }
                    }
                    NSApp.terminate(nil)
                }
                return
            }
            if CommandLine.arguments.contains("--proxy-preview") {
                self.showSettings(initialTab: 4)
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
                             "--grant-screen", "--capture-probe", "--pin-demo",
                             "--hosts-e2e", "--menu-probe", "--paste-probe",
                             "--overlay-preview", "--clip-preview", "--text-probe", "--proxy-preview", "--proxy-run-probe", "--update-run-probe", "--rules-update-probe", "--app-update-probe"]
    /// 实验：策略在 finishLaunching 之后再改可能完不成激活握手，
    /// 所以 --regular-mode 在 app.run() 之前就把策略定成 .regular。
    static var earlyRegular: Bool { CommandLine.arguments.contains("--regular-mode") }

    /// 统计一下抓到的画面：全黑/全白基本就是权限没到位的症状。
    static func pixelStats(_ image: CGImage) -> String {
        guard let data = image.dataProvider?.data as Data? else { return "no data" }
        let bpp = image.bitsPerPixel / 8
        var minV = 255, maxV = 0, sum = 0, n = 0
        data.withUnsafeBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let total = raw.count / bpp
            let stride = max(1, total / 20_000)
            var i = 0
            while i < total {
                let o = i * bpp
                let v = (Int(p[o]) + Int(p[o + 1]) + Int(p[o + 2])) / 3
                minV = min(minV, v); maxV = max(maxV, v); sum += v; n += 1
                i += stride
            }
        }
        return "min=\(minV) max=\(maxV) avg=\(n > 0 ? sum / n : 0) samples=\(n)"
    }

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

    /// 开库 → 清孤儿文件 → 起轮询。全在后台，别挡首帧。
    func startClipboard() {
        Task { @MainActor in
            do {
                try await database.open(create: .clipboardV1)
                _ = try media.garbageCollect(liveSHAs: Set(await clipboardStore.allMediaSHAs()))
                if recording { monitor.start() }
                model.clipboardStore = clipboardStore
                model.mediaStore = media
                clipboardPanel.onPinImage = { data in
                    PinManager.shared.pinAtCursor(pngData: data)
                }
            } catch {
                log("剪贴板初始化失败: \(error)\n")
            }
        }
    }

    func makeActions() -> AppActions {
        model.onHotkeysChanged = { [weak self] _ in self?.reregisterHotkeys() }
        captureFlow.onMessage = { text in DegradeNotice.shared.show(text) }
        pinsOfCapture.settingsProvider = { [weak self] in self?.model.settings ?? .default }
        pinsOfCapture.magnifySignProvider = { [weak self] in
            (self?.model.settings.scrollZoomDirection ?? .upMagnifies) == .downMagnifies ? -1 : 1
        }
        return AppActions(
            clipboard: { [weak self] in self?.clipboardPanel.show() },
            hostsQuick: { [weak self] in self?.showHostsPanel() },
            captureRegion: { [weak self] in self?.captureFlow.startRegionCapture() },
            captureFull: { [weak self] in self?.captureFlow.captureFullScreenAndPin() },
            killAllPins: { PinManager.shared.closeAll() },
            togglePause: { [weak self] in self?.toggleRecording() },
            openPermissions: { [weak self] in self?.showSettings() },
            openSettings: { [weak self] in self?.showSettings() },
            toggleLoginItem: { [weak self] in self?.model.toggleLoginItem() },
            hostsToggle: { [weak self] id in
                Task { @MainActor in await self?.hostsModel.toggle(id) }
            },
            hostsManagementToggle: { [weak self] in
                Task { @MainActor in
                    await self?.hostsModel.setManagementOn(!(self?.hostsModel.library.managementOn ?? true))
                }
            },
            quit: { NSApp.terminate(nil) })
    }

    /// 暂停/恢复采集。菜单勾选态与 monitor 状态必须同源，否则会出现
    /// "菜单显示记录中、其实已经停了"。
    func toggleRecording() {
        recording.toggle()
        if recording { monitor.start() } else { monitor.stop(reason: .userPaused) }
    }

    /// App 退出前必须收干净代理：停内核 + 关系统代理。
    /// 漏了关系统代理的话，用户整个系统流量还指向已死的本地端口 → 全网打不开。
    /// 软件更新：启动后延迟查一次，之后按间隔定时查。探针模式不查（别打扰、别触发网络）。
    func startUpdateChecks() {
        guard !Self.isProbeMode else { return }
        let s = model.settings.update
        guard s.autoCheck else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.runUpdateCheck() }
        let interval = TimeInterval(max(1, s.checkIntervalHours) * 3600)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.runUpdateCheck()
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    func runUpdateCheck() {
        Task { @MainActor in
            await model.softwareUpdate.check()
            if case .available(let info) = model.softwareUpdate.status {
                DegradeNotice.shared.show("发现新版本 v\(info.version)，去「设置 → 通用」更新")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        proxyModel.shutdown()
    }

    func showSettings(initialTab: Int = 0) {
        // 已开过就复用（切 tab 只在首次创建时定位；重复深链不是主路径，不为此加机制）
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(model: model, hostsModel: hostsModel, proxyModel: proxyModel, initialTab: initialTab)
        }
        settingsWindow?.show()
    }

    /// `⌘⇧H`：快速切换浮层。勾选攒着，关闭时一次性应用。
    func showHostsPanel() {
        let panel = HostsQuickPanelView()
        panel.load(hostsSnapshot.rows.map {
            HostsQuickPanelView.Row(id: $0.id, group: $0.group, name: $0.name,
                                    enabled: $0.enabled, kindLabel: "")
        })
        panel.onChanged = { [weak self] ids in
            Task { @MainActor in
                for id in ids { await self?.hostsModel.toggle(id) }
            }
        }
        panel.onCancel = { [weak self] in
            self?.hostsPanel = nil
            self?.panelPresenter.dismissCurrent(reason: .explicitClose)
        }
        hostsPanel = panel
        panelPresenter.show(content: panel, anchor: .cursor, width: 360, height: 380) { [weak self] _ in
            self?.hostsPanel?.flushPending()
            self?.hostsPanel = nil
        }
    }

    let panelPresenter = PanelPresenter.shared

    func showPlaceholder() {
        PanelPresenter.shared.show(content: PlaceholderPanelView(text: "M0 占位浮层"),
                                   anchor: .cursor, width: 320, height: 120) { _ in }
    }
}

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
