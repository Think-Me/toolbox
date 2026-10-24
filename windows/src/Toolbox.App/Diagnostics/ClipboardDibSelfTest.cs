using Toolbox.App.Clipboard;

namespace Toolbox.App.Diagnostics;

/// <summary>
/// CF_DIB → PNG 的自检。
///
/// 为什么需要它：这条路径只有在真机上复制一张图片时才会走到，而"复制图片"没法在脚本里做
/// （PowerShell 的 Add-Type / 反射加载都被安全策略拦住）。所以这里合成一张 64×48 的
/// 24 位 DIB 直接喂给转换函数，验证"补 BMP 文件头"那段逻辑没算错。
/// </summary>
internal static class ClipboardDibSelfTest
{
    private const int Width = 64;
    private const int Height = 48;

    public static (bool Ok, string Detail) Run()
    {
        var stride = (Width * 24 + 31) / 32 * 4;
        var dib = new byte[40 + stride * Height];

        WriteInt32(dib, 0, 40);              // biSize
        WriteInt32(dib, 4, Width);           // biWidth
        WriteInt32(dib, 8, Height);          // biHeight（正数 = 自底向上）
        WriteInt16(dib, 12, 1);              // biPlanes
        WriteInt16(dib, 14, 24);             // biBitCount
        WriteInt32(dib, 20, stride * Height); // biSizeImage

        // 填非零像素：全零数据即使偏移算错也可能"看起来能解码"，测不出问题
        for (var i = 40; i < dib.Length; i++) dib[i] = (byte)(i % 251);

        var png = ClipboardMonitor.DibToPng(dib);
        if (png is null) return (false, "转换返回 null");

        var size = ClipboardMonitor.SizeOf(png);
        if (size is null) return (false, "PNG 无法解码");
        if (size.Value.Width != Width || size.Value.Height != Height)
            return (false, $"尺寸不符，期望 {Width}x{Height}，实际 {size.Value.Width}x{size.Value.Height}");

        return (true, $"{Width}x{Height} ok {png.Length} bytes");
    }

    private static void WriteInt32(byte[] buffer, int offset, int value)
    {
        buffer[offset] = (byte)value;
        buffer[offset + 1] = (byte)(value >> 8);
        buffer[offset + 2] = (byte)(value >> 16);
        buffer[offset + 3] = (byte)(value >> 24);
    }

    private static void WriteInt16(byte[] buffer, int offset, short value)
    {
        buffer[offset] = (byte)value;
        buffer[offset + 1] = (byte)(value >> 8);
    }
}
