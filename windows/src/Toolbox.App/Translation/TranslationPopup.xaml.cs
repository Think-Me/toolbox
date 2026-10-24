using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Toolbox.App.Clipboard;
using Toolbox.App.Shell;

namespace Toolbox.App.Translation;

/// <summary>
/// 翻译浮窗。与剪贴板面板不同，它**不随失焦消失**——用户要一边看译文一边切回原文，
/// 「钉住」之后连 Esc 都不关，只有点 × 或再按一次热键里的关闭才走。
/// </summary>
internal partial class TranslationPopup : Window
{
    private readonly TranslationController _controller;
    private readonly Func<string?> _readSelection;
    private readonly Action<string> _report;
    private readonly Func<IntPtr> _getTargetWindow;

    private string? _result;
    private bool _pinned;

    public TranslationPopup(TranslationController controller, Func<string?> readSelection,
                            Func<IntPtr> getTargetWindow, Action<string> report)
    {
        _controller = controller;
        _readSelection = readSelection;
        _getTargetWindow = getTargetWindow;
        _report = report;

        InitializeComponent();
        PreviewKeyDown += OnPreviewKeyDown;
        _controller.Completed += OnTranslationCompleted;
    }

    /// <summary>划词入口：读选区 → 显示 → 异步翻译。没有选中文本时不弹窗。</summary>
    public void Toggle()
    {
        if (IsVisible)
        {
            Close();
            return;
        }

        var text = _readSelection();
        if (string.IsNullOrWhiteSpace(text))
        {
            _report("没有选中文本，无法翻译");
            return;
        }

        SourceText.Text = text.Length > 300 ? text[..300] + "…" : text;
        ResultText.Text = "翻译中…";
        EngineText.Text = "";
        _result = null;

        PositionOnScreen();
        Show();
        Activate();
        _controller.Begin(text);
    }

    private void OnTranslationCompleted(string engine, string? error, string? text)
    {
        // 翻译在后台线程完成，UI 更新必须回 UI 线程
        Dispatcher.BeginInvoke(() =>
        {
            EngineText.Text = engine;
            if (error is not null)
            {
                ResultText.Foreground = System.Windows.Media.Brushes.Firebrick;
                ResultText.Text = $"翻译失败：{error}";
                _result = null;
                return;
            }

            ResultText.Foreground = System.Windows.Media.Brushes.Black;
            ResultText.Text = text;
            _result = text;
        });
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
        _report(ClipboardPaste.WriteText(_result) ? "译文已复制" : "复制失败，剪贴板被占用");
    }

    private void OnReplaceClick(object sender, RoutedEventArgs e)
    {
        if (_result is null) return;
        var target = _getTargetWindow();
        if (target == IntPtr.Zero)
        {
            _report("找不到原窗口，无法替换");
            return;
        }

        if (!ClipboardPaste.WriteText(_result))
        {
            _report("写入剪贴板失败，无法替换");
            return;
        }

        NativeMethods.SetForegroundWindow(target);
        if (!WaitForForeground(target))
        {
            _report("原窗口没切回来，请手动粘贴");
            return;
        }

        _report(ClipboardPaste.SendCombo(NativeMethods.VkControl, NativeMethods.VkV).Ok
            ? "已替换原文"
            : "合成按键失败，请手动粘贴");
    }

    private void OnRetranslateClick(object sender, RoutedEventArgs e)
    {
        var text = SourceText.Text;
        if (string.IsNullOrWhiteSpace(text)) return;
        ResultText.Text = "翻译中…";
        _controller.Begin(text);
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
}
