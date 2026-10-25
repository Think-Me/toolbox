using System.Windows;
using System.Windows.Media.Imaging;

namespace Toolbox.App.Capture;

/// <summary>
/// 所有贴图的总管（对齐 macOS PinManager）：
/// 追踪每一张贴图、总开关关闭、把剪贴板图片钉到光标处。
/// 刻意只暴露最小面给别的模块（剪贴板面板的「贴图」就靠它）。
/// </summary>
internal sealed class PinManager
{
    private readonly List<PinWindow> _pins = [];

    public int Count => _pins.Count;

    /// <summary>在指定屏幕矩形钉一张图（截图结果走这里）。</summary>
    public PinWindow Pin(BitmapSource source, Rect bounds) => Pin(source, bounds, new PinCallbacks());

    public PinWindow Pin(BitmapSource source, Rect bounds, PinCallbacks callbacks)
    {
        var window = new PinWindow(source, bounds, callbacks);
        window.Closed += (_, _) => _pins.Remove(window);
        _pins.Add(window);
        window.Show();
        return window;
    }

    /// <summary>
    /// 钉在光标处（剪贴板图片条目走这里：没有"原选区位置"可参照）。
    /// 太大就按屏幕工作区 80% 缩小，否则贴图大到拖不出边界。
    /// </summary>
    public PinWindow? PinAtCursor(BitmapSource source, PinCallbacks callbacks)
    {
        var width = source.PixelWidth;
        var height = source.PixelHeight;
        if (width <= 0 || height <= 0) return null;

        if (!Shell.NativeMethods.GetCursorPos(out var cursor)) return null;
        var monitor = Shell.NativeMethods.MonitorFromPoint(cursor, Shell.NativeMethods.MonitorDefaultToNearest);
        var info = new Shell.NativeMethods.MonitorInfo { Size = System.Runtime.InteropServices.Marshal.SizeOf<Shell.NativeMethods.MonitorInfo>() };
        Shell.NativeMethods.GetMonitorInfo(monitor, ref info);

        var scale = info.Monitor.Right - info.Monitor.Left > 0 && source.DpiX > 0 ? source.DpiX / 96.0 : 1.0;
        double dipWidth = width / scale;
        double dipHeight = height / scale;

        var workWidth = info.Work.Right - info.Work.Left;
        var workHeight = info.Work.Bottom - info.Work.Top;

        // 太大就按屏幕工作区 80% 缩小，否则贴图大到一次看不完、也拖不出边界
        var maxW = workWidth / scale * 0.8;
        var maxH = workHeight / scale * 0.8;
        if (dipWidth > maxW || dipHeight > maxH)
        {
            var k = Math.Min(maxW / dipWidth, maxH / dipHeight);
            dipWidth *= k;
            dipHeight *= k;
        }

        // 光标工作区坐标 -> 本屏 DIP 坐标（WPF Left/Top 是虚拟桌面 DIP，直接换算）
        var workLeftDip = info.Work.Left / scale;
        var workTopDip = info.Work.Top / scale;
        var originX = Math.Clamp(cursor.X / scale - dipWidth / 2, workLeftDip, workLeftDip + workWidth / scale - dipWidth);
        var originY = Math.Clamp(cursor.Y / scale - dipHeight / 2, workTopDip, workTopDip + workHeight / scale - dipHeight);

        return Pin(source, new Rect(originX, originY, dipWidth, dipHeight), callbacks);
    }

    /// <summary>F3：穿透模式下这是唯一的救急出口，必须无条件能关掉所有贴图。</summary>
    public void CloseAll()
    {
        foreach (var window in _pins.ToList()) window.Close();
    }

    /// <summary>截图前调用。贴图默认参与截图，设置反过来时才隐藏。</summary>
    public void HideForCaptureIfConfigured(bool participate)
    {
        if (participate) return;
        foreach (var window in _pins.Where(w => w.IsVisible).ToList()) window.Hide();
        _restoreOnCaptureEnd = true;
    }

    public void RestoreAfterCapture(bool participate)
    {
        if (participate || !_restoreOnCaptureEnd) return;
        _restoreOnCaptureEnd = false;
        foreach (var window in _pins.ToList()) window.Show();
    }

    private bool _restoreOnCaptureEnd;
}

/// <summary>贴图窗需要的宿主能力：复制（带自写标记）与存盘。</summary>
internal sealed record PinCallbacks(
    Action<BitmapSource>? CopyToClipboard = null,
    Action<BitmapSource>? SaveToFile = null,
    Action<string>? Report = null)
{
    public static PinCallbacks None { get; } = new();
}
