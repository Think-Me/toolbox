using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Threading;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Toolbox.App.Actions;
using Toolbox.App.Clipboard;
using Toolbox.App.Capture;
using Toolbox.App.Diagnostics;
using Toolbox.App.Hotkeys;
using Toolbox.App.Hosts;
using Toolbox.App.Settings;
using Toolbox.App.Shell;
using Toolbox.App.Translation;
using Toolbox.App.Update;
using Toolbox.Core.Clipboard;
using Toolbox.Core.Hosts;
using Toolbox.Core.Infrastructure;
using Toolbox.Core.Settings;
using Toolbox.Core.Shell;
using Toolbox.Core.Translation;
using Velopack;

namespace Toolbox.App;

public partial class App : Application
{
    private readonly AppPaths _paths = AppPaths.Standard();
    private readonly ProbeReport _probe = new();

    private RollingFileLogger? _log;
    private SettingsStore? _store;
    private AppSettings _settings = new();
    private SingleInstance? _instance;
    private TaskbarSink? _sink;
    private TrayIcon? _tray;
    private TrayMenu? _menu;
    private HotkeyService? _hotkeys;
    private HotkeyRegistrationTable? _hotkeyTable;
    private AppActionTable? _actions;
    private SettingsWindow? _settingsWindow;
    private ClipboardStore? _clipboardStore;
    private ClipboardMonitor? _monitor;
    private ClipboardPanelWindow? _clipboardPanel;
    private TranslationController? _translationController;
    private TranslationPopup? _translationPopup;
    private HostsStore? _hostsStore;
    private HostsLibrary _hostsLibrary = new();
    private bool _applyingHosts;
    private DispatcherTimer? _clipboardCoalesce;

    /// <summary>呼出面板之前的前台窗口，粘贴要打回这里。</summary>
    private IntPtr _pasteTarget;

    private bool _probeMode;
    private bool _pasteProbeMode;
    private bool _translateProbeMode;
    private bool _captureProbeMode;
    private bool _reportingCrash;
    private bool _recording = true;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // Velopack 的生命周期钩子必须在最前面：更新器重启时会带特殊参数进来
        VelopackApp.Build().Run();

        _probeMode = e.Args.Contains("--probe");
        _pasteProbeMode = e.Args.Contains("--paste-probe");
        _translateProbeMode = e.Args.Contains("--translate-probe");
        _captureProbeMode = e.Args.Contains("--capture-probe");

        _paths.EnsureDirectories();
        _log = new RollingFileLogger(_paths.LogsDirectory);
        // 异常钩子必须最先装：后面任何一行炸了都要能被记下来。
        InstallCrashHandlers();
        _log.Info($"启动 pid={Environment.ProcessId} probe={_probeMode}");

        _instance = SingleInstance.Acquire();
        if (!_instance.IsPrimary)
        {
            // 已经有实例在跑：让它把设置窗弹出来，自己安静退出。
            SingleInstance.SignalPrimary();
            _log.Info("已有实例在运行，本次启动退出");
            if (_probeMode)
            {
                // 让"第二个实例跑 --probe"这件事能被脚本观察到，而不是静默退出。
                _probe.Line("single-instance.primary=false");
                _probe.Write(_paths.ProbeReport);
            }
            Shutdown(0);
            return;
        }

        _instance.ActivationRequested += () => Dispatcher.BeginInvoke(ShowSettings);

        _store = new SettingsStore(_paths.Settings);
        _settings = _store.Load();

        _sink = new TaskbarSink();
        _tray = new TrayIcon(_sink.Handle);
        _sink.TrayCallback = _tray.HandleCallback;
        _sink.TaskbarCreated += OnTaskbarCreated;
        _sink.HotkeyReceived = OnHotkeyMessage;
        _tray.ActivateRequested += ShowTrayMenu;

        var trayInstalled = _tray.Install();
        if (!trayInstalled) _log.Error("托盘安装失败：" + _tray.LastError);

        _menu = new TrayMenu(_sink.Handle);
        _hotkeys = new HotkeyService(_sink.Handle);
        _hotkeyTable = HotkeyRegistrationTable.From(_settings.Hotkeys);
        _actions = BuildActions();
        _translationController = new TranslationController(
            () => _settings.Translation,
            LoadAiKey(_paths.AiKeyFile));

        var failures = _hotkeys.RegisterAll(_hotkeyTable);
        ReportHotkeyFailures(failures);

        _clipboardStore = new ClipboardStore(_paths.ClipboardDatabase, _paths.MediaDirectory);
        _monitor = new ClipboardMonitor(_clipboardStore, _settings, _log);
        var orphaned = ClipboardMedia.Cleanup(_paths.MediaDirectory, _clipboardStore.AllMediaShas());
        if (orphaned > 0) _log?.Info($"清理孤立媒体文件 {orphaned} 个");

        _hostsStore = new HostsStore(_paths.HostsRules);
        _hostsLibrary = _hostsStore.Load();

        _sink.ClipboardUpdated = OnClipboardUpdated;
        if (!NativeMethods.AddClipboardFormatListener(_sink.Handle))
            _log?.Error("注册剪贴板监听失败，历史采集不可用");

        // 粘贴链路的确定性自检：绕开托盘/热键，直接驱动 ClipboardPaste。
        // 必须在没有别的实例运行时做（单实例守卫在上面的分支里）。
        if (_pasteProbeMode)
        {
            RunPasteProbe();
            return;
        }

        // 翻译链路自检：打真实引擎接口，把原始响应体落进报告，用于解析层调试。
        if (_translateProbeMode)
        {
            RunTranslateProbe();
            return;
        }

        // 抓屏自检：BitBlt + 裁剪 + PNG 编码，产物落盘供人工核对。
        if (_captureProbeMode)
        {
            RunCaptureProbe();
            return;
        }

        if (_probeMode)
        {
            FinishProbe(trayInstalled, failures);
            return;
        }

        // 自动更新：仅安装版生效（绿色目录/调试跳过）；网络不可用静默降级
        var updateService = new UpdateService(
            () => _settings.UpdateUrl,
            ReportStatus,
            (manager, updateInfo) => manager.ApplyUpdatesAndRestart(updateInfo));
        updateService.CheckForUpdates();

        _log?.Info($"骨架就绪：托盘={trayInstalled} 热键 {TotalHotkeys - failures.Count}/{TotalHotkeys}");
    }

    private static int TotalHotkeys => Enum.GetValues<HotkeyId>().Length;

    /// <summary>
    /// 一次复制会按格式连发多条 WM_CLIPBOARDUPDATE（Text / UnicodeText / OEMText …）。
    /// 不合并的话同一条内容会被读三遍，copy_count 也被虚增。用一个很短的定时器把突发并成一次。
    /// </summary>
    private void OnClipboardUpdated()
    {
        _clipboardCoalesce ??= CreateCoalesceTimer();
        _clipboardCoalesce.Stop();
        _clipboardCoalesce.Start();
    }

    private DispatcherTimer CreateCoalesceTimer()
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(60) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            var item = _monitor?.Capture();
            if (item is not null) _log?.Info($"采集 {item.Kind}：{item.DisplayPreview}");
        };
        return timer;
    }

    /// <summary>
    /// 粘贴链路自检：写剪贴板 → 验自写抑制 → 向记事本发 Ctrl+V。
    /// 目标窗口由调用方保证（先开一个标题为 "Untitled - Notepad" 的记事本）。
    /// </summary>
    private void RunPasteProbe()
    {
        var target = NativeMethods.FindWindow(null, "Untitled - Notepad");
        _probe.Line($"paste.targethwnd=0x{target.ToInt64():X}");
        if (target == IntPtr.Zero) _probe.Fail("找不到记事本窗口，请先打开一个空的记事本");

        var item = new ClipboardItem
        {
            Kind = ClipboardKind.Text,
            Text = $"Toolbox 粘贴探针 {DateTime.Now:HHmmss}",
            ByteLength = 64,
        };

        var (outcome, message) = ClipboardPaste.Paste(_clipboardStore!, item, _monitor!, target);
        _probe.Line($"paste.outcome={outcome} {message}");
        if (outcome == PasteOutcome.Failed) _probe.Fail("粘贴失败：" + message);

        // 自己写完剪贴板后，采集必须被自写抑制挡住，否则历史里会出现重复条目
        var echoed = _monitor!.Capture();
        _probe.Line(echoed is null ? "paste.selfwrite-suppressed=true" : "paste.selfwrite-suppressed=FALSE");
        if (echoed is not null) _probe.Fail("自写抑制失效，历史里会多出重复条目");

        _probe.Write(_paths.ProbeReport);
        _log?.Info($"paste-probe 完成 ok={_probe.Ok}");
        Shutdown(_probe.Ok ? 0 : 1);
    }

    /// <summary>
    /// 翻译链路自检：直接打有道 / MyMemory 的真实接口，把**原始响应体**写进报告。
    /// 引擎解析挂了的时候，没有原始响应根本没法修 —— 这里就是为了拿到它。
    /// </summary>
    private void RunTranslateProbe()
    {
        var text = "hello world";

        // OnStartup 在 UI 线程上：HTTP 续体会回到 Dispatcher，直接 GetResult() 就是死锁。
        // Task.Run 把续体扔到线程池，彻底脱离 UI 上下文。
        var (youdaoStatus, youdaoBody) = Task.Run(() => ProbeHttp(() =>
        {
            using var client = new HttpClient();
            var form = new Dictionary<string, string> { ["q"] = text, ["from"] = "auto", ["to"] = "zh-CHS" };
            using var response = client.PostAsync("https://aidemo.youdao.com/trans",
                new System.Net.Http.FormUrlEncodedContent(form)).GetAwaiter().GetResult();
            return (response.StatusCode, response.Content.ReadAsStringAsync().GetAwaiter().GetResult());
        })).GetAwaiter().GetResult();
        _probe.Line($"youdao.status={youdaoStatus}");
        _probe.Line($"youdao.body={TruncateForProbe(youdaoBody)}");

        var (myMemoryStatus, myMemoryBody) = Task.Run(() => ProbeHttp(() =>
        {
            using var client = new HttpClient();
            var url = "https://api.mymemory.translated.net/get?q=hello%20world&langpair=en%7Czh-CN";
            using var response = client.GetAsync(url).GetAwaiter().GetResult();
            return (response.StatusCode, response.Content.ReadAsStringAsync().GetAwaiter().GetResult());
        })).GetAwaiter().GetResult();
        _probe.Line($"mymemory.status={myMemoryStatus}");
        _probe.Line($"mymemory.body={TruncateForProbe(myMemoryBody)}");

        try
        {
            var result = Task.Run(() => new TranslationService().TranslateAsync(
                text, null, _settings.Translation, CancellationToken.None)).GetAwaiter().GetResult();
            _probe.Line($"translate.result=[{result.Engine.ShortLabel()}] {result.Text}");
        }
        catch (Exception error)
        {
            _probe.Fail($"translate failed: {error.GetType().Name}: {error.Message}");
        }

        _probe.Write(_paths.ProbeReport);
        _log?.Info($"translate-probe 完成 ok={_probe.Ok}");
        Shutdown(_probe.Ok ? 0 : 1);
    }

    private static (System.Net.HttpStatusCode Status, string Body) ProbeHttp(
        Func<(System.Net.HttpStatusCode, string)> request)
    {
        try { return request(); }
        catch (Exception error) { return (0, $"{error.GetType().Name}: {error.Message}"); }
    }

    private static string TruncateForProbe(string body) =>
        body.Length <= 600 ? body : body[..600] + "…(截断)";

    /// <summary>
    /// 抓屏自检：BitBlt 抓光标所在显示器 -> 裁一块 200x150 -> 分别编码 PNG 落盘。
    /// 遮罩窗的交互没法被自动化驱动（分层窗口枚举不到、整屏截图又会遮掉普通窗口），
    /// 所以抓屏/裁剪这条底层链路用确定性产物验证，选区交互靠人工验收。
    /// </summary>
    private void RunCaptureProbe()
    {
        var capture = Capture.CaptureService.CaptureCursorMonitor();
        if (capture is null)
        {
            _probe.Fail("抓屏返回空");
            _probe.Write(_paths.ProbeReport);
            Shutdown(1);
            return;
        }

        _probe.Line($"capture.size={capture.PixelWidth}x{capture.PixelHeight}");
        _probe.Line($"capture.dpiScale={capture.DpiScale:0.00}");
        _probe.Line($"capture.monitor=({capture.MonitorPixels.Left},{capture.MonitorPixels.Top})-({capture.MonitorPixels.Right},{capture.MonitorPixels.Bottom})");

        var full = Path.Combine(_paths.LocalRoot, "capture-probe-full.png");
        SavePng(capture.Image, full);
        _probe.Line($"capture.full={(File.Exists(full) ? new FileInfo(full).Length : -1)} {full}");

        var croppedPng = Capture.CaptureService.ToPng(capture.Image, 10, 10, 200, 150);
        var cropped = Path.Combine(_paths.LocalRoot, "capture-probe-cropped.png");
        File.WriteAllBytes(cropped, croppedPng);
        _probe.Line($"capture.cropped={croppedPng.Length} {cropped}");

        // 裁剪尺寸必须严格等于请求值，多一像素少一像素都是坐标系换算错了
        if (croppedPng.Length <= 0) _probe.Fail("裁剪 PNG 为空");
        try
        {
            var decoded = BitmapFrame.Create(new MemoryStream(File.ReadAllBytes(cropped)));
            if (decoded.PixelWidth != 200 || decoded.PixelHeight != 150)
                _probe.Fail($"裁剪尺寸 {decoded.PixelWidth}x{decoded.PixelHeight}，期望 200x150");
        }
        catch (Exception error)
        {
            _probe.Fail("裁剪 PNG 解码失败：" + error.Message);
        }

        _probe.Write(_paths.ProbeReport);
        _log?.Info($"capture-probe 完成 ok={_probe.Ok}");
        Shutdown(_probe.Ok ? 0 : 1);
    }

    private static void SavePng(BitmapSource source, string path)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(source));
        using var stream = File.Create(path);
        encoder.Save(stream);
    }

    /// <summary>explorer 崩溃重启会清掉所有托盘图标，只能重新挂一次。</summary>
    private void OnTaskbarCreated()
    {
        var ok = _tray?.ReAdd() ?? false;
        _log?.Info($"explorer 重启后重挂托盘：{ok}");
    }

    /// <summary>WM_HOTKEY 只有 id，没有"这是哪个功能"；映射在这里统一收口。</summary>
    private bool OnHotkeyMessage(int id)
    {
        if (_hotkeys is null || !_hotkeys.Dispatch(id)) return false;

        var hotkeyId = (HotkeyId)id;
        var action = AppActionTable.ForHotkey(hotkeyId);
        _log?.Info($"热键 {HotkeyRegistrationTable.DisplayName(hotkeyId)} → {action}");

        // 热键不改变前台窗口，此刻的前台就是用户想粘贴回去 / 替换原文的地方
        if (action is TrayAction.Clipboard or TrayAction.Translate)
            _pasteTarget = NativeMethods.GetForegroundWindow();

        _actions?.Invoke(action);
        return true;
    }

    /// <summary>区域截图：先冻结屏幕，再盖遮罩窗划选区。</summary>
    private void StartCapture()
    {
        _log?.Info("截图：开始抓屏");
        var capture = CaptureService.CaptureCursorMonitor();
        if (capture is null)
        {
            _log?.Info("截图：抓屏返回空");
            ReportStatus("抓屏失败");
            return;
        }
        _log?.Info($"截图：{capture.PixelWidth}×{capture.PixelHeight} dpiScale={capture.DpiScale:0.00}");

        var overlay = new CaptureOverlay(
            capture,
            cropped => System.Windows.Clipboard.SetImage(cropped),
            (cropped, bounds) =>
            {
                new PinWindow(cropped, bounds).Show();
                _log?.Info($"贴图 {bounds.Width:0}×{bounds.Height:0}");
            },
            ReportStatus);
        overlay.Show();
        _log?.Info($"截图：遮罩窗已显示 visible={overlay.IsVisible}");
    }

    private void ShowClipboardPanel()
    {
        if (_clipboardStore is null || _monitor is null) return;

        _clipboardPanel ??= new ClipboardPanelWindow(_clipboardStore, PasteClipboardItem, ReportStatus);
        _clipboardPanel.ShowPanel();
    }

    /// <summary>自己往剪贴板写了东西（粘贴、采集回退的恢复）都要打标记，否则会被自己的监听再采一遍。</summary>
    private void MarkSelfWrite() => _monitor?.MarkSelfWrite();

    /// <summary>划词翻译：读选区（读不到时气泡提示），弹浮窗并异步翻译。</summary>
    private void ShowTranslation()
    {
        if (_translationController is null) return;

        _translationPopup ??= new TranslationPopup(_translationController, new TranslationContext
        {
            Settings = () => _settings.Translation,
            ReadSelection = () => SelectionReader.Read(MarkSelfWrite),
            PersistSettings = settings =>
            {
                _store?.Save(_settings);
                _log?.Info("翻译设置已保存");
            },
            GetTargetWindow = () => _pasteTarget,
            Report = ReportStatus,
            MarkSelfWrite = MarkSelfWrite,
        });
        _translationPopup.Toggle();
    }

    private (PasteOutcome Outcome, string Message) PasteClipboardItem(ClipboardItem item)
    {
        if (_clipboardStore is null || _monitor is null) return (PasteOutcome.Failed, "");

        var result = ClipboardPaste.Paste(_clipboardStore, item, _monitor, _pasteTarget);
        _log?.Info($"粘贴 {item.Kind}：{result.Outcome} {result.Message}");
        return result;
    }

    private void ReportStatus(string message)
    {
        _log?.Info(message);
        _tray?.ShowBalloon("Toolbox", message);
    }

    private void ShowTrayMenu()
    {
        if (_menu is null || _actions is null) return;

        // 菜单一打开前台就变成我们自己的窗口，所以要在打开之前记住用户当时在哪个窗口。
        _pasteTarget = NativeMethods.GetForegroundWindow();

        // 每次打开都重新取快照：勾选状态必须是"此刻的真实状态"，不能是启动时的。
        var items = TrayMenuBuilder.Items(_settings, _recording, LoginItem.IsEnabled(), BuildHostsSnapshot());
        var (action, ruleId) = _menu.Show(items);
        if (action == TrayAction.None) return;

        if (!_actions.Invoke(action, ruleId)) _log?.Info($"菜单动作 {action} 没有绑定处理器");
    }

    private AppActionTable BuildActions()
    {
        var table = new AppActionTable();

        table.Bind(TrayAction.OpenSettings, _ => ShowSettings());
        table.Bind(TrayAction.Quit, _ => Shutdown(0));
        table.Bind(TrayAction.TogglePause, _ => ToggleRecording());
        table.Bind(TrayAction.ToggleLoginItem, _ => ToggleLoginItem());
        table.Bind(TrayAction.Clipboard, _ => ShowClipboardPanel());
        table.Bind(TrayAction.Translate, _ => ShowTranslation());
        table.Bind(TrayAction.HostsPanel, _ => ShowSettings());
        table.Bind(TrayAction.HostsManagementToggle, _ => ToggleHostsManagement());
        table.Bind(TrayAction.HostsRuleToggle, ruleId => ToggleHostsRule(ruleId));
        table.Bind(TrayAction.CaptureRegion, _ => StartCapture());

        return table;
    }

    /// <summary>托盘子菜单要显示的真实规则快照，每次开菜单重新取。</summary>
    private TrayHostsSnapshot BuildHostsSnapshot() => new(
        _hostsLibrary.ManagementOn,
        _hostsLibrary.Groups.SelectMany(g => g.Rules)
            .Select(rule => new TrayHostsRow(
                rule.Id,
                _hostsLibrary.Groups.FirstOrDefault(g => g.Rules.Contains(rule))?.Name ?? "",
                rule.Name,
                rule.Enabled))
            .ToList());

    private void ToggleHostsManagement()
    {
        _hostsLibrary.ManagementOn = !_hostsLibrary.ManagementOn;
        _hostsStore?.Save(_hostsLibrary);
        _log?.Info($"Hosts 托管 → {(_hostsLibrary.ManagementOn ? "开" : "关")}");
        ApplyHostsInBackground();
    }

    private void ToggleHostsRule(Guid? ruleId)
    {
        if (ruleId is not { } id) return;
        var rule = _hostsLibrary.AllRules.FirstOrDefault(r => r.Id == id);
        if (rule is null) return;

        rule.Enabled = !rule.Enabled;
        _hostsStore?.Save(_hostsLibrary);
        _log?.Info($"规则 {rule.Name} → {(rule.Enabled ? "启用" : "停用")}");
        ApplyHostsInBackground();
    }

    /// <summary>
    /// hosts 应用要过 UAC（最多等 60s），绝不能在 UI 线程上等；
    /// 连续切换时合并成一次，前一次没做完就跳过本次。
    /// </summary>
    private void ApplyHostsInBackground()
    {
        if (_applyingHosts)
        {
            _log?.Info("上一次 hosts 应用还没结束，跳过本次");
            return;
        }
        _applyingHosts = true;

        Task.Run(() =>
        {
            try
            {
                CompileResult compiled;
                try
                {
                    compiled = _hostsLibrary.Compile(HostsApplier.ReadCurrentHosts());
                }
                catch (BrokenSentinelException error)
                {
                    // 绝不猜范围：块坏了只能引导用户恢复，而不是替他改
                    ReportStatus($"hosts 托管块损坏：{error.Message}。可在设置里恢复原始 hosts。");
                    return;
                }

                var outcome = HostsApplier.Apply(compiled.Content);
                _log?.Info($"应用 hosts：ok={outcome.Ok} {outcome.Message}");
                ReportStatus(outcome.Ok ? outcome.Message : $"应用 hosts 失败：{outcome.Message}");
            }
            finally
            {
                _applyingHosts = false;
            }
        });
    }

    private void ToggleRecording()
    {
        _recording = !_recording;
        if (_monitor is not null) _monitor.Paused = !_recording;
        _log?.Info(_recording ? "恢复剪贴板记录" : "暂停剪贴板记录");
    }

    private void ToggleLoginItem()
    {
        var target = !LoginItem.IsEnabled();
        if (LoginItem.Set(target) is { } error)
        {
            // 写失败就不装成功：菜单下次仍从注册表读，显示的是系统里的真实状态。
            _log?.Error($"开机自启设置失败：{error}");
            _tray?.ShowBalloon("开机自启设置失败", error, isError: true);
            return;
        }

        _log?.Info($"开机自启 → {target}");
    }

    private void ShowSettings()
    {
        if (_settingsWindow is null)
        {
            _settingsWindow = new SettingsWindow(BuildContext());
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        }

        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    private SettingsContext BuildContext() => new()
    {
        Paths = _paths,
        Settings = _settings,
        Hotkeys = _hotkeyTable!,
        Failures = _hotkeys?.Failures ?? [],
        ProbeFree = gesture => _hotkeys?.Probe(gesture) ?? false,
        ApplyHotkeys = ApplyHotkeys,
        SaveSettings = () => _store?.Save(_settings),
        LoadAiKey = () => LoadAiKey(_paths.AiKeyFile) ?? "",
        SaveAiKey = key => SaveAiKey(key),
        Hosts = () => _hostsLibrary,
        HostsChanged = () =>
        {
            _hostsStore?.Save(_hostsLibrary);
            ApplyHostsInBackground();
        },
        RestoreHosts = () => Task.Run(() =>
        {
            var outcome = HostsApplier.Restore();
            _log?.Info($"恢复 hosts：ok={outcome.Ok} {outcome.Message}");
            ReportStatus(outcome.Ok ? outcome.Message : $"恢复 hosts 失败：{outcome.Message}");
        }),
        Log = message => _log?.Info(message),
    };

    /// <summary>AI Key 用 DPAPI 保护，读不到（没存/坏文件）就按没有 Key 处理，AI 引擎会给出明确错误。</summary>
    private static string? LoadAiKey(string file)
    {
        try
        {
            if (!File.Exists(file)) return null;
            var encrypted = File.ReadAllBytes(file);
            var plain = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plain);
        }
        catch
        {
            return null;
        }
    }

    private static void SaveAiKey(string key)
    {
        // 调用方保证目录存在（AppPaths.EnsureDirectories 在启动时跑过）
        var file = AppPaths.Standard().AiKeyFile;
        var encrypted = ProtectedData.Protect(Encoding.UTF8.GetBytes(key), null, DataProtectionScope.CurrentUser);
        File.WriteAllBytes(file, encrypted);
    }

    /// <summary>绑定表已经改过之后再调用：写盘 → 全部重注册 → 返回失败项。</summary>
    private IReadOnlyList<HotkeyFailure> ApplyHotkeys()
    {
        _hotkeyTable!.ApplyTo(_settings.Hotkeys);
        _store!.Save(_settings);

        var failures = _hotkeys!.RegisterAll(_hotkeyTable);
        if (failures.Count > 0) ReportHotkeyFailures(failures);
        _log?.Info($"热键已保存并重新注册，失败 {failures.Count} 项");
        return failures;
    }

    private void ReportHotkeyFailures(IReadOnlyList<HotkeyFailure> failures)
    {
        foreach (var failure in failures)
        {
            _log?.Error($"热键 {HotkeyRegistrationTable.DisplayName(failure.Id)}" +
                        $"（{failure.Gesture}）：{failure.Reason}");
        }

        if (failures.Count == 0) return;

        var detail = string.Join("\n",
            failures.Select(f => $"· {HotkeyRegistrationTable.DisplayName(f.Id)}：{f.Reason}"));
        _tray?.ShowBalloon($"有 {failures.Count} 个快捷键没能注册", detail, isError: true);
    }

    private void FinishProbe(bool trayInstalled, IReadOnlyList<HotkeyFailure> failures)
    {
        _probe.Line($"version={typeof(App).Assembly.GetName().Version}");
        _probe.Line($"settings={_paths.Settings}");
        _probe.Line($"logs={_paths.LogsDirectory}");
        _probe.Line("single-instance.primary=true");
        _probe.Line($"sink.hwnd=0x{_sink!.Handle.ToInt64():X}");
        _probe.Line($"tray.installed={trayInstalled}");
        if (!trayInstalled) _probe.Fail("托盘安装失败：" + _tray!.LastError);

        _probe.Line($"hotkeys.registered={TotalHotkeys - failures.Count}/{TotalHotkeys}");
        foreach (var id in Enum.GetValues<HotkeyId>())
        {
            var gesture = _hotkeyTable!.Get(id)?.ToString() ?? "未设置";
            var failure = failures.FirstOrDefault(f => f.Id == id);
            _probe.Line(failure is null
                ? $"hotkey.{id}={gesture} ok"
                : $"hotkey.{id}={gesture} FAILED {failure.Reason}");
        }
        if (failures.Count > 0) _probe.Fail($"{failures.Count} 个热键注册失败");

        _probe.Line($"loginitem.enabled={LoginItem.IsEnabled()}");

        var latest = _clipboardStore?.Latest();
        _probe.Line($"clipboard.paused={_monitor?.Paused}");
        _probe.Line(latest is null
            ? "clipboard.latest=<empty>"
            : $"clipboard.latest={latest.Kind} \"{latest.DisplayPreview}\" from={latest.SourceProcess}");

        var dib = ClipboardDibSelfTest.Run();
        _probe.Line($"clipboard.dib-convert={dib.Detail}");
        if (!dib.Ok) _probe.Fail("DIB→PNG 转换失败：" + dib.Detail);

        // XAML 的解析错误编译期查不出来，只有真的构造一次才知道。不 Show，避免弹窗打断脚本。
        try
        {
            var probeWindow = new SettingsWindow(BuildContext());
            probeWindow.Close();
            _probe.Line("settingswindow.loaded=true");
        }
        catch (Exception error)
        {
            _probe.Fail("设置窗加载失败：" + error.Message);
        }

        try
        {
            var probePanel = new ClipboardPanelWindow(_clipboardStore!, PasteClipboardItem, _ => { });
            probePanel.Close();
            _probe.Line("clipboardpanel.loaded=true");
        }
        catch (Exception error)
        {
            _probe.Fail("剪贴板面板加载失败：" + error.Message);
        }

        _probe.Write(_paths.ProbeReport);
        _log?.Info($"probe 完成 ok={_probe.Ok} -> {_paths.ProbeReport}");
        Shutdown(_probe.Ok ? 0 : 1);
    }

    private void InstallCrashHandlers()
    {
        // UI 线程异常：记日志 + 气泡，然后让进程继续活着（常驻 App 不该被一次 UI 异常带走）
        DispatcherUnhandledException += (_, args) =>
        {
            ReportCrash("Dispatcher", args.Exception);
            args.Handled = true;
        };

        // 非 UI 线程的未捕获异常无法恢复，只求把现场写进日志
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
            ReportCrash("AppDomain", args.ExceptionObject as Exception);

        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            ReportCrash("Task", args.Exception);
            args.SetObserved();
        };
    }

    private void ReportCrash(string source, Exception? error)
    {
        // 处理崩溃时再崩会无限递归，直接放弃
        if (_reportingCrash) return;
        _reportingCrash = true;
        try
        {
            _log?.Error($"[{source}] 未处理异常：{error}");
            _tray?.ShowBalloon("Toolbox 遇到错误", error?.Message ?? "未知错误", isError: true);
        }
        catch
        {
            // 连记录都失败就只能放弃了
        }
        finally
        {
            _reportingCrash = false;
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        // 注销热键要在窗口销毁之前：Handle 没了再注销会失败，键位就留在系统里被"占着"。
        _hotkeys?.UnregisterAll();
        if (_sink is not null) NativeMethods.RemoveClipboardFormatListener(_sink.Handle);
        _clipboardStore?.Dispose();
        _tray?.Dispose();
        _sink?.Dispose();
        _instance?.Dispose();
        _log?.Info("退出");
        base.OnExit(e);
    }
}
