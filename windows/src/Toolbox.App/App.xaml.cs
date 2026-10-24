using System.Windows;
using Toolbox.App.Diagnostics;
using Toolbox.App.Shell;
using Toolbox.Core.Infrastructure;

namespace Toolbox.App;

public partial class App : Application
{
    private readonly AppPaths _paths = AppPaths.Standard();
    private readonly ProbeReport _probe = new();

    private RollingFileLogger? _log;
    private SingleInstance? _instance;
    private TaskbarSink? _sink;
    private TrayIcon? _tray;

    private bool _probeMode;
    private bool _reportingCrash;

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
                // 让 "--probe 第二个实例" 这件事可被脚本观察到，而不是静默退出。
                _probe.Line("single-instance.primary=false");
                _probe.Write(_paths.ProbeReport);
            }
            Shutdown(0);
            return;
        }

        _instance.ActivationRequested += () => Dispatcher.BeginInvoke(ShowSettings);

        _sink = new TaskbarSink();
        _tray = new TrayIcon(_sink.Handle);
        _sink.TrayCallback = _tray.HandleCallback;
        _sink.TaskbarCreated += OnTaskbarCreated;
        _tray.ActivateRequested += ShowTrayMenu;

        var trayInstalled = _tray.Install();
        if (!trayInstalled) _log.Error("托盘安装失败：" + _tray.LastError);

        if (_probeMode)
        {
            FinishProbe(trayInstalled);
            return;
        }

        _log.Info(trayInstalled ? "骨架就绪，等待热键/菜单" : "骨架就绪（托盘不可用）");
    }

    /// <summary>explorer 崩溃重启会清掉所有托盘图标，只能重新挂一次。</summary>
    private void OnTaskbarCreated()
    {
        var ok = _tray?.ReAdd() ?? false;
        _log?.Info($"explorer 重启后重挂托盘：{ok}");
    }

    private void ShowTrayMenu()
    {
        // 菜单在 S3 接入；现在只记录，方便确认回调链路通了。
        _log?.Info("托盘被点击");
    }

    private void ShowSettings()
    {
        // 设置窗在 S4 接入。
        _log?.Info("请求打开设置（窗口待接入）");
        _tray?.ShowBalloon("Toolbox", "已经在运行了。设置窗口将在下一步接入。");
    }

    private void FinishProbe(bool trayInstalled)
    {
        _probe.Line($"version={typeof(App).Assembly.GetName().Version}");
        _probe.Line($"settings={_paths.Settings}");
        _probe.Line($"logs={_paths.LogsDirectory}");
        _probe.Line("single-instance.primary=true");
        _probe.Line($"sink.hwnd=0x{_sink!.Handle.ToInt64():X}");
        _probe.Line($"tray.installed={trayInstalled}");
        if (!trayInstalled) _probe.Fail("托盘安装失败：" + _tray!.LastError);

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
        _tray?.Dispose();
        _sink?.Dispose();
        _instance?.Dispose();
        _log?.Info("退出");
        base.OnExit(e);
    }
}
