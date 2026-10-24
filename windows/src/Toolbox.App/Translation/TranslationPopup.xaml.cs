using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Toolbox.App.Clipboard;
using Toolbox.App.Shell;
using Toolbox.Core.Translation;

namespace Toolbox.App.Translation;

/// <summary>
/// 翻译浮窗。与剪贴板面板不同，它**不随失焦消失**——用户要一边看译文一边切回原文，
/// 「钉住」之后连 Esc 都不关，只有点 × 或再按一次热键里的关闭才走。
/// </summary>
internal partial class TranslationPopup : Window
{
    private static readonly IReadOnlyList<TranslationEngine> Engines = Enum
        .GetValues<TranslationEngine>()
        .ToArray();

    private readonly TranslationController _controller;
    private readonly TranslationContext _context;
    private readonly Speaker _speaker = new();
    private readonly Dictionary<TranslationEngine, string> _engineLabels;

    private string? _source;
    private string? _result;
    private bool _pinned;
    private bool _suppressEngineEvents;

    public TranslationPopup(TranslationController controller, TranslationContext context)
    {
        _controller = controller;
        _context = context;

        InitializeComponent();
        PreviewKeyDown += OnPreviewKeyDown;
        _controller.Completed += OnTranslationCompleted;

        _engineLabels = Engines.ToDictionary(e => e, e => e.ShortLabel());
        EngineCombo.ItemsSource = _engineLabels.Values.ToList();
    }

    /// <summary>划词入口：读选区 → 显示 → 异步翻译。没有选中文本时气泡提示，不弹空窗。</summary>
    public void Toggle()
    {
        if (IsVisible)
        {
            Close();
            return;
        }

        var text = _context.ReadSelection();
        if (string.IsNullOrWhiteSpace(text))
        {
            _context.Report("没有选中文本，无法翻译");
            return;
        }

        _source = text;
        SourceText.Text = text.Length > 300 ? text[..300] + "…" : text;
        ShowResult(null, "翻译中…");
        SyncEngineCombo();
        PositionOnScreen();
        Show();
        Activate();
        _controller.Begin(text);
    }

    private void ShowResult(string? error, string? text)
    {
        if (error is not null)
        {
            ResultText.Foreground = System.Windows.Media.Brushes.Firebrick;
            ResultText.Text = $"翻译失败：{error}";
            _result = null;
            return;
        }

        ResultText.Foreground = System.Windows.Media.Brushes.Black;
        ResultText.Text = text ?? "";
        _result = string.IsNullOrEmpty(text) ? null : text;
    }

    private void OnTranslationCompleted(string engine, string? error, string? text)
    {
        // 翻译在后台线程完成，UI 更新必须回 UI 线程。
        // 引擎名交给 Controller 层记日志，这里不回写 ComboBox——用户手动选中的引擎不能被结果回调顶掉。
        Dispatcher.BeginInvoke(() => ShowResult(error, text));
    }

    /// <summary>居中到主屏工作区。多显示器限制与剪贴板面板相同。</summary>
    private void PositionOnScreen()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - Width) / 2;
        Top = area.Top + (area.Height - ActualHeight) / 2;
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape) return;
        if (_pinned) return;   // 钉住时 Esc 不关，避免看译文时误触
        Close();
        e.Handled = true;
    }

    private void SyncEngineCombo()
    {
        var current = _context.Settings().Engine;
        _suppressEngineEvents = true;
        EngineCombo.SelectedItem = _engineLabels.TryGetValue(current, out var label) ? label : null;
        _suppressEngineEvents = false;
    }

    private void OnEngineChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressEngineEvents) return;

        var label = EngineCombo.SelectedItem as string;
        var engine = _engineLabels.FirstOrDefault(p => p.Value == label).Key;
        if (engine == default) return;

        var settings = _context.Settings();
        if (settings.Engine == engine) return;

        settings.Engine = engine;
        _context.PersistSettings(settings);
        _context.Report($"翻译引擎 → {engine.ShortLabel()}");

        // 切换引擎后立刻重译当前原文，行为与 Mac 版一致
        if (_source is not null && IsVisible)
        {
            ResultText.Text = "翻译中…";
            _controller.Begin(_source);
        }
    }

    private void OnPinClick(object sender, RoutedEventArgs e)
    {
        _pinned = !_pinned;
        PinButton.Content = _pinned ? "已钉住" : "钉住";
    }

    private void OnCloseClick(object sender, RoutedEventArgs e) => Close();

    private void OnCopyClick(object sender, RoutedEventArgs e)
    {
        if (_result is null) return;
        // 用户主动复制译文：这是真实复制，不打自写标记，应该进历史
        _context.Report(ClipboardPaste.WriteText(_result) ? "译文已复制" : "复制失败，剪贴板被占用");
    }

    private void OnSpeakClick(object sender, RoutedEventArgs e)
    {
        if (_result is null) return;
        var error = _speaker.Speak(_result, _context.Settings().TargetLanguage);
        if (error is not null) _context.Report(error);
    }

    private void OnReplaceClick(object sender, RoutedEventArgs e)
    {
        if (_result is null) return;
        var target = _context.GetTargetWindow();
        if (target == IntPtr.Zero)
        {
            _context.Report("找不到原窗口，无法替换");
            return;
        }

        if (!ClipboardPaste.WriteText(_result))
        {
            _context.Report("写入剪贴板失败，无法替换");
            return;
        }

        NativeMethods.SetForegroundWindow(target);
        if (!WaitForForeground(target))
        {
            _context.Report("原窗口没切回来，请手动粘贴");
            return;
        }

        _context.Report(ClipboardPaste.SendCombo(NativeMethods.VkControl, NativeMethods.VkV).Ok
            ? "已替换原文"
            : "合成按键失败，请手动粘贴");
    }

    private void OnRetranslateClick(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(_source)) return;
        ResultText.Text = "翻译中…";
        _controller.Begin(_source);
    }

    private static bool WaitForForeground(IntPtr target)
    {
        for (var attempt = 0; attempt < 30; attempt++)
        {
            if (NativeMethods.GetForegroundWindow() == target) return true;
            Thread.Sleep(10);
        }
        return false;
    }

    protected override void OnClosed(EventArgs e)
    {
        _speaker.Stop();
        base.OnClosed(e);
    }
}
