using System.Windows;
using System.Windows.Threading;
using Toolbox.App.Actions;
using Toolbox.App.Clipboard;
using Toolbox.App.Diagnostics;
using Toolbox.App.Hotkeys;
using Toolbox.App.Settings;
using Toolbox.App.Shell;
using Toolbox.Core.Clipboard;
using Toolbox.Core.Infrastructure;
using Toolbox.Core.Settings;
using Toolbox.Core.Shell;

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
    private DispatcherTimer? _clipboardCoalesce;

    /// <summary>呼出面板之前的前台窗口，粘贴要打回这里。</summary>
    private IntPtr _pasteTarget;

    private bool _probeMode;
    private bool _pasteProbeMode;
    private bool _reportingCrash;
    private bool _recording = true;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _probeMode = e.Args.Contains("--probe");
        _pasteProbeMode = e.Args.Contains("--paste-probe");

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

        var failures = _hotkeys.RegisterAll(_hotkeyTable);
        ReportHotkeyFailures(failures);

        _clipboardStore = new ClipboardStore(_paths.ClipboardDatabase, _paths.MediaDirectory);
        _monitor = new ClipboardMonitor(_clipboardStore, _settings, _log);
        var orphaned = ClipboardMedia.Cleanup(_paths.MediaDirectory, _clipboardStore.AllMediaShas());
        if (orphaned > 0) _log?.Info($"清理孤立媒体文件 {orphaned} 个");
        _sink.ClipboardUpdated = OnClipboardUpdated;
        if (!NativeMethods.AddClipboardFormatListener(_sink.Handle))
            _log.Error("注册剪贴板监听失败，历史采集不可用");

        // 粘贴链路的确定性自检：绕开托盘/热键，直接驱动 ClipboardPaste。
        // 必须在没有别的实例运行时做（单实例守卫在上面的分支里）。
        if (_pasteProbeMode)
        {
            RunPasteProbe();
            return;
        }

        if (_probeMode)
        {
            FinishProbe(trayInstalled, failures);
            return;
        }

        _log.Info($"骨架就绪：托盘={trayInstalled} 热键 {TotalHotkeys - failures.Count}/{TotalHotkeys}");
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

        // 热键不改变前台窗口，此刻的前台就是用户想粘贴回去的地方
        if (action == TrayAction.Clipboard) _pasteTarget = NativeMethods.GetForegroundWindow();

        _actions?.Invoke(action);
        return true;
    }

    private void ShowClipboardPanel()
    {
        if (_clipboardStore is null || _monitor is null) return;

        _clipboardPanel ??= new ClipboardPanelWindow(_clipboardStore, PasteClipboardItem, ReportStatus);
        _clipboardPanel.ShowPanel();
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
        var items = TrayMenuBuilder.Items(_settings, _recording, LoginItem.IsEnabled(), TrayHostsSnapshot.Empty);
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

        // 还没做的模块：菜单照常可点，点了明确告诉用户什么时候会有，而不是静默无反应。
        TrayAction[] pending =
        [
            TrayAction.Translate,
            TrayAction.HostsPanel,
            TrayAction.HostsManagementToggle,
            TrayAction.HostsRuleToggle,
            TrayAction.CaptureRegion,
        ];
        foreach (var action in pending) table.Bind(action, _ => ReportPending(action));

        return table;
    }

    private void ReportPending(TrayAction action)
    {
        var (name, phase) = Pending(action);
        _log?.Info($"{name} 尚未实现（{phase}）");
        _tray?.ShowBalloon(name, $"这个功能将在 {phase} 提供。");
    }

    private static (string Name, string Phase) Pending(TrayAction action) => action switch
    {
        TrayAction.Clipboard => ("剪贴板历史", "P1"),
        TrayAction.Translate => ("划词翻译", "P2"),
        TrayAction.HostsPanel or TrayAction.HostsRuleToggle or TrayAction.HostsManagementToggle =>
            ("Hosts 规则", "P3"),
        TrayAction.CaptureRegion => ("区域截图", "P4"),
        _ => ("该功能", "后续版本"),
    };

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
        Hotkeys = _hotkeyTable!,
        Failures = _hotkeys?.Failures ?? [],
        ProbeFree = gesture => _hotkeys?.Probe(gesture) ?? false,
        ApplyHotkeys = ApplyHotkeys,
        Log = message => _log?.Info(message),
    };

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
