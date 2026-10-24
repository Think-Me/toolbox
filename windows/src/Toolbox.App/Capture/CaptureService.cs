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
/// BitBlt 抓屏。只抓光标所在的那台显示器（v1 限制，README 已知差异）：
/// 跨多台不同 DPI 的显示器拼一张图，遮罩窗的坐标换算会复杂一个数量级，先不做。
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

        // PerMonitorV2 下逐显示器取 DPI；失败回落 96
        var dpiResult = NativeMethods.GetDpiForMonitor(monitor, 0, out var dpiX, out var dpiY);
        var scale = dpiResult == 0 && dpiX > 0 ? dpiX / 96.0 : 1.0;

        var width = info.Monitor.Right - info.Monitor.Left;
        var height = info.Monitor.Bottom - info.Monitor.Top;
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
                            screenDc, info.Monitor.Left, info.Monitor.Top,
                            NativeMethods.Srccopy | NativeMethods.CaptureBlt))
                        return null;

                    var pixels = new byte[stride * height];
                    Marshal.Copy(bits, pixels, 0, pixels.Length);

                    // 屏幕是 BGR 顺序内存，Bgr32 正好对应，无需逐像素换
                    var image = BitmapSource.Create(width, height, 96, 96,
                        PixelFormats.Bgr32, null, pixels, stride);
                    image.Freeze();

                    return new ScreenCapture(image, scale, info.Monitor);
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
