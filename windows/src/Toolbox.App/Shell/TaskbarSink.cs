using System.Windows.Interop;

namespace Toolbox.App.Shell;

/// <summary>
/// 隐藏的**顶层**窗口，作为托盘回调、WM_HOTKEY 和 explorer 重启通知的落点。
///
/// 刻意不用 message-only 窗口（ParentWindow = HWND_MESSAGE）：
/// <c>TaskbarCreated</c> 是 <c>RegisterWindowMessage</c> 出来的广播消息，只发给顶层窗口。
/// 挂在 message-only 窗口上的托盘图标在 explorer 崩溃重启后就再也回不来了。
/// </summary>
internal sealed class TaskbarSink : IDisposable
{
    private readonly HwndSource _source;
    private readonly int _taskbarCreatedMessage;
    private bool _disposed;

    /// <summary>explorer 重启后触发，调用方负责重新 Shell_NotifyIcon(NIM_ADD)。</summary>
    public event Action? TaskbarCreated;

    /// <summary>WM_HOTKEY：参数是热键 id。返回 true 表示已处理。</summary>
    public Func<int, bool>? HotkeyReceived { get; set; }

    /// <summary>托盘图标回调：参数是 (通知码, 图标 id)。</summary>
    public Action<int, int>? TrayCallback { get; set; }

    /// <summary>WM_CLIPBOARDUPDATE：有程序改了剪贴板。</summary>
    public Action? ClipboardUpdated { get; set; }

    public TaskbarSink()
    {
        _taskbarCreatedMessage = NativeMethods.RegisterWindowMessage("TaskbarCreated");

        var parameters = new HwndSourceParameters("ToolboxSink")
        {
            Width = 0,
            Height = 0,
            WindowStyle = NativeMethods.WsPopup,
            ExtendedWindowStyle = NativeMethods.WsExToolWindow,
            ParentWindow = IntPtr.Zero,
        };
        _source = new HwndSource(parameters);
        _source.AddHook(WndProc);
    }

    public IntPtr Handle => _source.Handle;

    private IntPtr WndProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == _taskbarCreatedMessage)
        {
            TaskbarCreated?.Invoke();
            handled = true;
        }
        else if (message == NativeMethods.WmHotkey)
        {
            handled = HotkeyReceived?.Invoke(wParam.ToInt32()) ?? false;
        }
        else if (message == NativeMethods.WmClipboardUpdate)
        {
            ClipboardUpdated?.Invoke();
            handled = true;
        }
        else if (message == NativeMethods.TrayCallbackMessage)
        {
            // v4 语义：lParam 低字是通知码，高字是图标 id
            TrayCallback?.Invoke(lParam.ToInt32() & 0xFFFF, (lParam.ToInt32() >> 16) & 0xFFFF);
            handled = true;
        }

        return IntPtr.Zero;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _source.RemoveHook(WndProc);
        _source.Dispose();
    }
}
