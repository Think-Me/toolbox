using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Toolbox.Core.Settings;

namespace Toolbox.App.Settings;

/// <summary>
/// 热键录制框。点一下进入录制，按组合键后回车提交、Esc 取消（与 Mac 版同一套语义）。
///
/// 关键一点：Alt 组合键在 WPF 里 <c>e.Key</c> 是 <see cref="Key.System"/>，
/// 真正的键在 <c>e.SystemKey</c>。漏了这句，Ctrl+Alt+V 会被录成裸 V。
/// </summary>
public partial class HotkeyRecorderBox : UserControl
{
    private static readonly Brush IdleBorder = new SolidColorBrush(Color.FromRgb(0xC8, 0xC8, 0xC8));
    private static readonly Brush RecordingBorder = new SolidColorBrush(Color.FromRgb(0x1E, 0x88, 0xE5));

    private HotkeyGesture _current;
    private HotkeyGesture? _pending;
    private bool _recording;

    public HotkeyRecorderBox() => InitializeComponent();

    /// <summary>用户按 Enter 确认时触发。</summary>
    public Action<HotkeyRecorderBox, HotkeyGesture>? Committed { get; set; }

    /// <summary>用户按 Esc 或焦点移走时触发（撤销到原键位）。</summary>
    public Action<HotkeyRecorderBox>? Cancelled { get; set; }

    public HotkeyGesture Current => _current;

    public void SetGesture(HotkeyGesture gesture)
    {
        _current = gesture;
        _pending = null;
        _recording = false;
        Frame.BorderBrush = IdleBorder;
        Caption.Text = gesture.IsEmpty ? "点击录制" : gesture.ToString();
    }

    private void BeginRecording()
    {
        _recording = true;
        _pending = null;
        Frame.BorderBrush = RecordingBorder;
        Caption.Text = "等待按键… (Esc 取消)";
        Keyboard.Focus(this);
    }

    private void OnFrameMouseDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        BeginRecording();
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (!_recording) return;

        // Alt 组合键的真实键位在 SystemKey 上
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        e.Handled = true;

        if (key == Key.Escape)
        {
            Cancel();
            return;
        }

        if (key == Key.Enter)
        {
            if (_pending is { } confirmed)
            {
                StopRecording();
                Committed?.Invoke(this, confirmed);
            }
            return;
        }

        // 只按修饰键不算一次输入，等真正的主键
        if (IsModifierOnly(key)) return;

        var virtualKey = KeyInterop.VirtualKeyFromKey(key);
        if (virtualKey == 0) return;

        _pending = new HotkeyGesture(ModifiersFrom(Keyboard.Modifiers), virtualKey);
        Caption.Text = $"按下 {_pending.Value}，回车确认";
    }

    private void OnLostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        if (_recording) Cancel();
    }

    private void Cancel()
    {
        var wasRecording = _recording;
        StopRecording();
        if (wasRecording) Cancelled?.Invoke(this);
    }

    private void StopRecording()
    {
        _recording = false;
        _pending = null;
        Frame.BorderBrush = IdleBorder;
        Caption.Text = _current.IsEmpty ? "点击录制" : _current.ToString();
    }

    private static bool IsModifierOnly(Key key) => key
        is Key.LeftCtrl or Key.RightCtrl
        or Key.LeftAlt or Key.RightAlt
        or Key.LeftShift or Key.RightShift
        or Key.LWin or Key.RWin
        or Key.System or Key.None
        or Key.ImeProcessed or Key.DeadCharProcessed;

    private static HotkeyModifiers ModifiersFrom(ModifierKeys keys)
    {
        var result = HotkeyModifiers.None;
        if (keys.HasFlag(ModifierKeys.Control)) result |= HotkeyModifiers.Control;
        if (keys.HasFlag(ModifierKeys.Alt)) result |= HotkeyModifiers.Alt;
        if (keys.HasFlag(ModifierKeys.Shift)) result |= HotkeyModifiers.Shift;
        if (keys.HasFlag(ModifierKeys.Windows)) result |= HotkeyModifiers.Win;
        return result;
    }
}
