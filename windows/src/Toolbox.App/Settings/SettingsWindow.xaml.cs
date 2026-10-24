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
        PathsText.Text = string.Join(Environment.NewLine,
            $"设置：{_context.Paths.Settings}",
            $"日志：{_context.Paths.LogsDirectory}",
            $"剪贴板库：{_context.Paths.ClipboardDatabase}");
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
