using System.IO;
using System.Runtime.InteropServices;

namespace Toolbox.App.Shell;

/// <summary>
/// 托盘图标。用原生 Shell_NotifyIcon 而不是第三方控件库：
/// 依赖少、行为与系统一致，出问题也好对着文档查。
/// 一个坑是 explorer 重启会把图标清掉，必须监听 TaskbarCreated 后重新 NIM_ADD。
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    private const int IconId = 1;

    private readonly IntPtr _window;
    private IntPtr _icon;
    private bool _added;
    private bool _disposed;

    public TrayIcon(IntPtr window) => _window = window;

    /// <summary>左键/右键/快捷键选中都算"要打开菜单"。</summary>
    public event Action? ActivateRequested;

    public bool IsAdded => _added;

    public string? LastError { get; private set; }

    /// <summary>加图标并切到 v4 语义。失败返回 false，原因在 LastError。</summary>
    public bool Install()
    {
        if (_added) return true;

        if (_icon == IntPtr.Zero) _icon = LoadIconFromAssets();

        var data = NewData();
        data.Flags = NativeMethods.NifMessage | NativeMethods.NifIcon | NativeMethods.NifTip;
        data.CallbackMessage = (uint)NativeMethods.TrayCallbackMessage;
        data.Icon = _icon;
        data.Tip = "Toolbox";

        if (!NativeMethods.Shell_NotifyIcon(NativeMethods.NimAdd, ref data))
        {
            LastError = "Shell_NotifyIcon(NIM_ADD) 失败";
            return false;
        }
        _added = true;

        // 切 v4 语义：回调参数变成"通知码 + 图标 id"。失败不致命，退化成 v0 也能用。
        var version = NewData();
        version.Version = NativeMethods.NotifyIconVersion4;
        NativeMethods.Shell_NotifyIcon(NativeMethods.NimSetVersion, ref version);

        return true;
    }

    /// <summary>explorer 重启后重新挂上。图标句柄还活着，不用重载。</summary>
    public bool ReAdd()
    {
        _added = false;
        return Install();
    }

    /// <summary>TaskbarSink 收到托盘回调后转进来。notification 是 v4 的通知码。</summary>
    public void HandleCallback(int notification, int iconId)
    {
        if (iconId != IconId) return;

        switch (notification)
        {
            case NativeMethods.NinSelect:
            case NativeMethods.NinKeySelect:
            case NativeMethods.WmContextMenu:
            case NativeMethods.WmLButtonUp:
            case NativeMethods.WmRButtonUp:
                ActivateRequested?.Invoke();
                break;
        }
    }

    /// <summary>气泡提示。用于"热键被占用""未处理异常"这类必须让用户看见的事。</summary>
    public void ShowBalloon(string title, string text, bool isError = false)
    {
        if (!_added) return;

        var data = NewData();
        data.Flags = NativeMethods.NifInfo;
        data.InfoTitle = Truncate(title, 63);
        data.Info = Truncate(text, 255);
        data.InfoFlags = isError ? NativeMethods.NiifError : NativeMethods.NiifInfo;
        NativeMethods.Shell_NotifyIcon(NativeMethods.NimModify, ref data);
    }

    private NativeMethods.NotifyIconData NewData() => new()
    {
        Size = Marshal.SizeOf<NativeMethods.NotifyIconData>(),
        Window = _window,
        Id = IconId,
        Tip = "",
        Info = "",
        InfoTitle = "",
    };

    /// <summary>按系统小图标尺寸取，125%/150% 缩放下才不会糊。</summary>
    private static IntPtr LoadIconFromAssets()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Assets", "Toolbox.ico");
        if (!File.Exists(path)) return IntPtr.Zero;

        var size = NativeMethods.GetSystemMetrics(NativeMethods.SmCxSmIcon);
        return NativeMethods.LoadImage(IntPtr.Zero, path, NativeMethods.ImageIcon,
                                      size, size, NativeMethods.LrLoadFromFile);
    }

    private static string Truncate(string text, int max) =>
        text.Length <= max ? text : text[..max];

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        if (_added)
        {
            var data = NewData();
            NativeMethods.Shell_NotifyIcon(NativeMethods.NimDelete, ref data);
            _added = false;
        }

        if (_icon != IntPtr.Zero)
        {
            NativeMethods.DestroyIcon(_icon);
            _icon = IntPtr.Zero;
        }
    }
}
