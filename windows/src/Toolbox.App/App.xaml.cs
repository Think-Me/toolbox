using System.Windows;
using Toolbox.App.Actions;
using Toolbox.App.Diagnostics;
using Toolbox.App.Hotkeys;
using Toolbox.App.Shell;
using Toolbox.Core.Infrastructure;
using Toolbox.Core.Settings;
using Toolbox.Core.Shell;

namespace Toolbox.App;

public partial class App : Application
{
    private readonly AppPaths _paths = AppPaths.Standard();
    private readonly ProbeReport _probe = new();

    private RollingFileLogger? _log;
    private AppSettings _settings = new();
    private SingleInstance? _instance;
    private TaskbarSink? _sink;
    private TrayIcon? _tray;
    private TrayMenu? _menu;
    private HotkeyService? _hotkeys;
    private HotkeyRegistrationTable? _hotkeyTable;
    private AppActionTable? _actions;

    private bool _probeMode;
    private bool _reportingCrash;
    private bool _recording = true;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _probeMode = e.Args.Contains("--probe");

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

        _settings = new SettingsStore(_paths.Settings).Load();

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

        if (_probeMode)
        {
            FinishProbe(trayInstalled, failures);
            return;
        }

        _log.Info($"骨架就绪：托盘={trayInstalled} 热键 {TotalHotkeys - failures.Count}/{TotalHotkeys}");
    }

    private static int TotalHotkeys => Enum.GetValues<HotkeyId>().Length;

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
        _actions?.Invoke(action);
        return true;
    }

    private void ShowTrayMenu()
    {
        if (_menu is null || _actions is null) return;

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

        // 还没做的模块：菜单照常可点，点了明确告诉用户什么时候会有，而不是静默无反应。
        TrayAction[] pending =
        [
            TrayAction.Clipboard,
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
        // 采集器在 P1 接入；现在先只维护状态，菜单勾选会立刻反映出来。
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
        // 设置窗在 S4 接入。
        _log?.Info("请求打开设置（窗口待接入）");
        _tray?.ShowBalloon("Toolbox", "已经在运行了。设置窗口将在下一步接入。");
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
        _tray?.Dispose();
        _sink?.Dispose();
        _instance?.Dispose();
        _log?.Info("退出");
        base.OnExit(e);
    }
}
