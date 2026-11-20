using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Toolbox.App.Hotkeys;
using Toolbox.App.Shell;
using Toolbox.Core.Settings;

namespace Toolbox.App.Settings;

/// <summary>设置窗。P0 只有「通用」页是真功能，其余四页明确标注待实现。</summary>
internal partial class SettingsWindow : Window
{
    private static readonly Brush OkBrush = new SolidColorBrush(Color.FromRgb(0x2E, 0x7D, 0x32));
    private static readonly Brush ErrorBrush = new SolidColorBrush(Color.FromRgb(0xB0, 0x00, 0x20));

    private readonly SettingsContext _context;
    private readonly Dictionary<HotkeyId, HotkeyRecorderBox> _recorders = [];

    public SettingsWindow(SettingsContext context)
    {
        _context = context;
        InitializeComponent();

        TranslationHost.Content = new TranslationTab(
            () => context.Settings.Translation,
            () => context.SaveSettings(),
            () => context.LoadAiKey(),
            key => context.SaveAiKey(key),
            message => context.Log(message));

        HostsHost.Content = new HostsTab(context);
        ClipboardHost.Content = new ClipboardTab(context.Settings.Clipboard, () => context.SaveSettings());
        CaptureHost.Content = new CaptureTab(context.Settings.Capture, () => context.SaveSettings());
        ProxyHost.Content = new Toolbox.App.Proxy.ProxyTab(context.Proxy);

        BuildHotkeyRows();
        ShowHotkeyFailures(context.Failures);
        LoadGeneralState();
    }

    private static int TotalHotkeys => Enum.GetValues<HotkeyId>().Length;

    private void BuildHotkeyRows()
    {
        foreach (var id in Enum.GetValues<HotkeyId>())
        {
            var row = new Grid { Margin = new Thickness(0, 0, 0, 8) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var label = new TextBlock
            {
                Text = HotkeyRegistrationTable.DisplayName(id),
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(label, 0);

            var recorder = new HotkeyRecorderBox();
            recorder.SetGesture(_context.Hotkeys.Get(id) ?? default);
            recorder.Committed = OnRecorderCommitted;
            recorder.Cancelled = _ => ShowHotkeyFailures(_context.Failures);
            Grid.SetColumn(recorder, 1);

            row.Children.Add(label);
            row.Children.Add(recorder);
            HotkeyRowsPanel.Children.Add(row);
            _recorders[id] = recorder;
        }
    }

    private void OnRecorderCommitted(HotkeyRecorderBox box, HotkeyGesture gesture)
    {
        var id = _recorders.First(pair => pair.Value == box).Key;

        if (RejectReason(id, gesture) is { } reason)
        {
            // 拒绝时把录制框退回原键位，别让界面停在一个没生效的值上
            box.SetGesture(_context.Hotkeys.Get(id) ?? default);
            ShowMessage(reason, isError: true);
            return;
        }

        _context.Hotkeys.Set(id, gesture);
        box.SetGesture(gesture);

        var failures = _context.ApplyHotkeys();
        ShowHotkeyFailures(failures);
        _context.Log($"快捷键 {HotkeyRegistrationTable.DisplayName(id)} → {gesture}");
    }

    /// <summary>null 表示可以接受。</summary>
    private string? RejectReason(HotkeyId id, HotkeyGesture gesture)
    {
        if (HotkeyRegistrationTable.Validate(gesture) is { } invalid) return invalid;

        if (HotkeyRegistrationTable.DetectConflict(id, gesture, _context.Hotkeys.Bindings) is { } conflict)
            return conflict;

        // 重录本行当前键位：键在自己手上，探测必然报"被占用"，必须直接放行
        if (_context.Hotkeys.Get(id) == gesture) return null;

        return _context.ProbeFree(gesture) ? null : $"「{gesture}」已被其它程序占用，换一个键位。";
    }

    private void ShowHotkeyFailures(IReadOnlyList<HotkeyFailure> failures)
    {
        if (failures.Count == 0)
        {
            ShowMessage($"全部 {TotalHotkeys} 个快捷键已生效。", isError: false);
            return;
        }

        var lines = failures.Select(f => $"· {HotkeyRegistrationTable.DisplayName(f.Id)}：{f.Reason}");
        ShowMessage(string.Join(Environment.NewLine, lines), isError: true);
    }

    private void ShowMessage(string text, bool isError)
    {
        HotkeyStatusText.Foreground = isError ? ErrorBrush : OkBrush;
        HotkeyStatusText.Text = text;
    }

    private void LoadGeneralState()
    {
        // 每次打开都回读注册表：用户可能在任务管理器里改过
        LaunchAtLoginCheck.IsChecked = LoginItem.IsEnabled();

        // 版本： assembly 的 InformationalVersion 优先（构建时可注入），否则 AssemblyVersion
        var assembly = typeof(SettingsWindow).Assembly;
        var informational = assembly.GetCustomAttribute<System.Reflection.AssemblyInformationalVersionAttribute>()
            ?.InformationalVersion;
        var versionText = "v" + (string.IsNullOrEmpty(informational) ? assembly.GetName().Version?.ToString(3) : informational);
        UpdateVersionText.Text = versionText;

        PathsText.Text = string.Join(Environment.NewLine,
            $"设置：{_context.Paths.Settings}",
            $"日志：{_context.Paths.LogsDirectory}",
            $"剪贴板库：{_context.Paths.ClipboardDatabase}");

        LoadUpdateState();
    }

    // ---- 软件更新（BUG-008：对齐 Mac 通用页的软件更新段）----

    private void LoadUpdateState()
    {
        var update = _context.Settings.Update;

        AutoCheckUpdateCheck.IsChecked = update.AutoCheck;
        IntervalRow.Visibility = update.AutoCheck ? Visibility.Visible : Visibility.Collapsed;
        IntervalBox.Text = update.CheckIntervalHours.ToString();

        UseProxyCheck.IsChecked = update.UseProxy;
        ProxyPortRow.Visibility = update.UseProxy ? Visibility.Visible : Visibility.Collapsed;
        ProxyPortBox.Text = update.ProxyPort.ToString();

        MirrorBox.Text = update.GithubMirror;

        _context.Update.Changed += OnUpdateServiceChanged;
        _context.Update.StatusReported += OnUpdateStatusReported;
        SyncInstallRow();
    }

    /// <summary>更新服务的状态变化（发现新版/下载进度/busy）回 UI 刷新。</summary>
    private void OnUpdateServiceChanged()
    {
        if (!IsLoaded) return;
        Dispatcher.BeginInvoke(SyncInstallRow);
    }

    /// <summary>更新服务的报告（气泡同款文本）回填到 UI 状态框。</summary>
    private void OnUpdateStatusReported(string message)
    {
        if (!IsLoaded) return;
        UpdateStatusText.Text = message;
    }

    private void SyncInstallRow()
    {
        var service = _context.Update;
        var info = service.PendingInstall;
        var hasUpdate = info is not null;
        UpdateInstallRow.Visibility = hasUpdate ? Visibility.Visible : Visibility.Collapsed;
        if (hasUpdate)
        {
            InstallUpdateButton.IsEnabled = !service.IsBusy;
            InstallUpdateButton.Content = service.IsBusy ? "下载中…" : $"下载并安装 v{info!.TargetFullRelease.Version}";
        }
    }

    private void OnCheckUpdateClick(object sender, RoutedEventArgs e)
    {
        UpdateStatusText.Text = "检查中…";
        _context.Update.CheckForUpdates();
    }

    private void OnManualDownloadClick(object sender, RoutedEventArgs e) =>
        _context.Update.OpenReleasesPage();

    private void OnInstallUpdateClick(object sender, RoutedEventArgs e) =>
        _context.Update.DownloadAndInstall();

    private void OnAutoCheckClick(object sender, RoutedEventArgs e)
    {
        var settings = _context.Settings.Update;
        settings.AutoCheck = AutoCheckUpdateCheck.IsChecked == true;
        IntervalRow.Visibility = settings.AutoCheck ? Visibility.Visible : Visibility.Collapsed;
        _context.SaveSettings();
        _context.Update.RefreshTimer();
        _context.Log($"自动检查更新 → {settings.AutoCheck}");
    }

    private void OnIntervalChanged(object sender, RoutedEventArgs e) => ApplyInterval();
    private void OnIntervalKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == System.Windows.Input.Key.Enter) ApplyInterval();
    }

    private void ApplyInterval()
    {
        var settings = _context.Settings.Update;
        if (!int.TryParse(IntervalBox.Text, out var hours))
        {
            IntervalBox.Text = settings.CheckIntervalHours.ToString();
            return;
        }
        var normalized = UpdateFeed.NormalizeIntervalHours(hours);
        if (normalized != hours) IntervalBox.Text = normalized.ToString();
        settings.CheckIntervalHours = normalized;
        _context.SaveSettings();
        _context.Update.RefreshTimer();
    }

    private void OnUseProxyClick(object sender, RoutedEventArgs e)
    {
        var settings = _context.Settings.Update;
        settings.UseProxy = UseProxyCheck.IsChecked == true;
        ProxyPortRow.Visibility = settings.UseProxy ? Visibility.Visible : Visibility.Collapsed;
        _context.SaveSettings();
        _context.Log($"更新走本地代理 → {settings.UseProxy}");
    }

    private void OnProxyPortChanged(object sender, RoutedEventArgs e) => ApplyProxyPort();
    private void OnProxyPortKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == System.Windows.Input.Key.Enter) ApplyProxyPort();
    }

    private void ApplyProxyPort()
    {
        var settings = _context.Settings.Update;
        if (!int.TryParse(ProxyPortBox.Text, out var port))
        {
            ProxyPortBox.Text = settings.ProxyPort.ToString();
            return;
        }
        var normalized = UpdateFeed.NormalizeProxyPort(port);
        if (normalized != port) ProxyPortBox.Text = normalized.ToString();
        settings.ProxyPort = normalized;
        _context.SaveSettings();
    }

    private void OnMirrorChanged(object sender, RoutedEventArgs e)
    {
        var settings = _context.Settings.Update;
        var mirror = MirrorBox.Text.Trim();
        if (mirror.Length > 0 && !mirror.StartsWith("http://") && !mirror.StartsWith("https://"))
        {
            UpdateStatusText.Text = "镜像前缀需要以 http:// 或 https:// 开头";
            MirrorBox.Text = settings.GithubMirror;
            return;
        }
        settings.GithubMirror = mirror;
        _context.SaveSettings();
    }

    private void OnLaunchAtLoginClick(object sender, RoutedEventArgs e)
    {
        var wanted = LaunchAtLoginCheck.IsChecked == true;

        if (LoginItem.Set(wanted) is { } error)
        {
            // 写失败就把勾选退回系统里的真实状态，不显示一个不存在的状态
            LaunchAtLoginCheck.IsChecked = LoginItem.IsEnabled();
            LaunchAtLoginError.Text = "设置失败：" + error;
            _context.Log($"开机自启设置失败：{error}");
            return;
        }

        LaunchAtLoginError.Text = "";
        _context.Log($"开机自启 → {wanted}");
    }
}
