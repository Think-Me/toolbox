using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Toolbox.App.Shell;

namespace Toolbox.App.Capture;

/// <summary>一次抓屏的结果：位图 + 该显示器的 DPI 与像素边界（选区换算要用）。</summary>
internal sealed record ScreenCapture(BitmapSource Image, double DpiScale, NativeMethods.Rect2 MonitorPixels)
{
    public int PixelWidth => MonitorPixels.Right - MonitorPixels.Left;
    public int PixelHeight => MonitorPixels.Bottom - MonitorPixels.Top;
}

/// <summary>
/// BitBlt 抓屏。区域截图抓**整个虚拟桌面**（所有显示器拼成一张，对齐 macOS
/// 覆盖虚拟桌面的行为）；全屏截图只抓光标所在那台。
/// 混合 DPI：拼图位图用光标所在屏的 DPI 做 DIP 换算，其它 DPI 不同的屏上
/// 选区尺寸会有偏差（README 已知差异）。
/// CAPTUREBLT 带上分层窗口，否则 Alt-Tab 之类的浮层会缺。
/// </summary>
internal static class CaptureService
{
    public static ScreenCapture? CaptureCursorMonitor()
    {
        if (!NativeMethods.GetCursorPos(out var cursor)) return null;

        var monitor = NativeMethods.MonitorFromPoint(
            new NativeMethods.Point { X = cursor.X, Y = cursor.Y },
            NativeMethods.MonitorDefaultToNearest);

        var info = new NativeMethods.MonitorInfo { Size = Marshal.SizeOf<NativeMethods.MonitorInfo>() };
        if (!NativeMethods.GetMonitorInfo(monitor, ref info)) return null;

        var scale = DpiScaleOf(monitor);
        return Blt(info.Monitor, scale);
    }

    /// <summary>整个虚拟桌面拼成一张位图（多显示器的并集，负坐标原点也已包含）。</summary>
    public static ScreenCapture? CaptureVirtualDesktop()
    {
        var left = NativeMethods.GetSystemMetrics(NativeMethods.SmXVirtualScreen);
        var top = NativeMethods.GetSystemMetrics(NativeMethods.SmYVirtualScreen);
        var width = NativeMethods.GetSystemMetrics(NativeMethods.SmCxVirtualScreen);
        var height = NativeMethods.GetSystemMetrics(NativeMethods.SmCyVirtualScreen);
        if (width <= 0 || height <= 0) return null;

        // DIP 换算用光标所在屏的 DPI（v1 限制：混合 DPI 下非光标屏会有偏差）
        double scale = 1;
        if (NativeMethods.GetCursorPos(out var cursor))
        {
            var monitor = NativeMethods.MonitorFromPoint(
                new NativeMethods.Point { X = cursor.X, Y = cursor.Y },
                NativeMethods.MonitorDefaultToNearest);
            scale = DpiScaleOf(monitor);
        }

        return Blt(new NativeMethods.Rect2
        {
            Left = left,
            Top = top,
            Right = left + width,
            Bottom = top + height,
        }, scale);
    }

    private static double DpiScaleOf(IntPtr monitor)
    {
        // PerMonitorV2 下逐显示器取 DPI；失败回落 96
        var dpiResult = NativeMethods.GetDpiForMonitor(monitor, 0, out var dpiX, out var _);
        return dpiResult == 0 && dpiX > 0 ? dpiX / 96.0 : 1.0;
    }

    private static ScreenCapture? Blt(NativeMethods.Rect2 rect, double scale)
    {
        var width = rect.Right - rect.Left;
        var height = rect.Bottom - rect.Top;
        if (width <= 0 || height <= 0) return null;

        var screenDc = NativeMethods.GetDC(IntPtr.Zero);
        if (screenDc == IntPtr.Zero) return null;

        try
        {
            var memDc = NativeMethods.CreateCompatibleDC(screenDc);
            if (memDc == IntPtr.Zero) return null;

            try
            {
                var stride = width * 4;
                var header = new NativeMethods.BitmapInfoHeader
                {
                    Size = (uint)Marshal.SizeOf<NativeMethods.BitmapInfoHeader>(),
                    Width = width,
                    Height = -height,          // 负数 = 自顶向下，行序和 WPF 一致
                    Planes = 1,
                    BitCount = 32,
                    Compression = 0,           // BI_RGB
                };
                var bmi = new NativeMethods.BitmapInfo { Header = header };

                var dib = NativeMethods.CreateDIBSection(
                    memDc, ref bmi, NativeMethods.DibRgbColors, out var bits, IntPtr.Zero, 0);
                if (dib == IntPtr.Zero || bits == IntPtr.Zero) return null;

                try
                {
                    NativeMethods.SelectObject(memDc, dib);
                    if (!NativeMethods.BitBlt(memDc, 0, 0, width, height,
                            screenDc, rect.Left, rect.Top,
                            NativeMethods.Srccopy | NativeMethods.CaptureBlt))
                        return null;

                    var pixels = new byte[stride * height];
                    Marshal.Copy(bits, pixels, 0, pixels.Length);

                    // 屏幕是 BGR 顺序内存，Bgr32 正好对应，无需逐像素换
                    var image = BitmapSource.Create(width, height, 96, 96,
                        PixelFormats.Bgr32, null, pixels, stride);
                    image.Freeze();

                    return new ScreenCapture(image, scale, rect);
                }
                finally
                {
                    NativeMethods.DeleteObject(dib);
                }
            }
            finally
            {
                NativeMethods.DeleteDC(memDc);
            }
        }
        finally
        {
            NativeMethods.ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    /// <summary>从整屏位图裁出选区（像素坐标），转成 PNG 字节。</summary>
    public static byte[] ToPng(BitmapSource source, int x, int y, int width, int height)
    {
        x = Math.Max(0, Math.Min(x, source.PixelWidth - 1));
        y = Math.Max(0, Math.Min(y, source.PixelHeight - 1));
        width = Math.Clamp(width, 1, source.PixelWidth - x);
        height = Math.Clamp(height, 1, source.PixelHeight - y);

        var cropped = new CroppedBitmap(source, new System.Windows.Int32Rect(x, y, width, height));
        using var stream = new MemoryStream();
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(cropped));
        encoder.Save(stream);
        return stream.ToArray();
    }
}
