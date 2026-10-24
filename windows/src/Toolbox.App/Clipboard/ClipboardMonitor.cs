using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Media.Imaging;
using Toolbox.App.Shell;
using Toolbox.Core.Clipboard;
using Toolbox.Core.Infrastructure;
using Toolbox.Core.Settings;

namespace Toolbox.App.Clipboard;

/// <summary>
/// 剪贴板采集。Windows 有真通知（<c>AddClipboardFormatListener</c> + <c>WM_CLIPBOARDUPDATE</c>），
/// 不像 macOS 只能轮询，所以这里不需要 300ms 定时器。
///
/// 格式优先级与 README 一致：文件列表 → PNG → DIB → 纯文本。
/// 先判文件列表是因为从资源管理器复制文件时，剪贴板里同时还有文本（文件名），
/// 先取文本会把"复制文件"记成一段字符串。
/// </summary>
internal sealed class ClipboardMonitor
{
    private readonly ClipboardStore _store;
    private readonly AppSettings _settings;
    private readonly ClipboardFilter _filter;
    private readonly RollingFileLogger? _log;

    private DateTimeOffset? _lastSelfWrite;

    public ClipboardMonitor(ClipboardStore store, AppSettings settings, RollingFileLogger? log)
    {
        _store = store;
        _settings = settings;
        _filter = new ClipboardFilter(settings.Clipboard);
        _log = log;
    }

    public event Action<ClipboardItem>? Captured;

    /// <summary>暂停采集时不读剪贴板、不落库。</summary>
    public bool Paused { get; set; }

    /// <summary>上一次读取失败的原因，便于 --probe 与日志解释"为什么没记下来"。</summary>
    public string? LastFailure { get; private set; }

    /// <summary>
    /// 自己往剪贴板写了东西（粘贴、或回写历史项）时调用。
    /// 否则自己的写入会被自己的监听再采集一遍，历史里出现重复条目。
    /// 时间窗判定在 <see cref="ClipboardFilter.IsSelfWrite"/>，因为目标程序可能回写剪贴板，光靠标记挡不住。
    /// </summary>
    public void MarkSelfWrite() => _lastSelfWrite = DateTimeOffset.Now;

    /// <summary>收到 WM_CLIPBOARDUPDATE 时调用。</summary>
    public ClipboardItem? Capture()
    {
        if (Paused) return null;

        var now = DateTimeOffset.Now;
        if (_filter.IsSelfWrite(now, _lastSelfWrite)) return null;

        // 关键：剪贴板只在"把字节拷出来"这段时间里持有，转码/落库全部放到关闭之后。
        // 期间别的程序是拿不到剪贴板的，做重活会让用户感觉到复制粘贴卡顿甚至失败。
        var raw = ReadRaw(out var failure);
        if (raw is null)
        {
            LastFailure = failure;
            if (!string.IsNullOrEmpty(failure)) _log?.Info($"剪贴板未采集：{failure}");
            return null;
        }

        var item = BuildItem(raw, now);
        if (item is null)
        {
            LastFailure = "内容无法解码";
            return null;
        }

        item.SourceProcess = ForegroundProcessName();

        var decision = _filter.Decide(item, _store.Latest(), now, _lastSelfWrite);
        if (decision == CaptureDecision.Ignore)
        {
            LastFailure = "按策略忽略（来源被排除 / 内容为空 / 超出大小上限）";
            return null;
        }

        var stored = _store.Add(item);
        _store.Prune(_settings.Clipboard.MaxItems);
        LastFailure = null;
        Captured?.Invoke(stored);
        return stored;
    }

    /// <summary>从剪贴板拷出来的原始内容。图片在这里还只是字节，没有转码。</summary>
    private sealed record RawCapture(ClipboardKind Kind, string? Text, List<string>? Files,
                                     byte[]? Image, bool ImageIsDib);

    private RawCapture? ReadRaw(out string failure)
    {
        if (!OpenWithRetry(out failure)) return null;

        try
        {
            if (NativeMethods.IsClipboardFormatAvailable(NativeMethods.CfHDrop))
            {
                var files = ReadFiles();
                if (files.Count > 0) return new RawCapture(ClipboardKind.FileUrls, null, files, null, false);
            }

            if (ReadImage() is { } image)
                return new RawCapture(ClipboardKind.Image, null, null, image.Bytes, image.IsDib);

            if (NativeMethods.IsClipboardFormatAvailable(NativeMethods.CfText))
            {
                var text = ReadText();
                if (!string.IsNullOrEmpty(text)) return new RawCapture(ClipboardKind.Text, text, null, null, false);
            }

            failure = "剪贴板里没有可识别的格式";
            return null;
        }
        finally
        {
            NativeMethods.CloseClipboard();
        }
    }

    private ClipboardItem? BuildItem(RawCapture raw, DateTimeOffset now)
    {
        var item = new ClipboardItem
        {
            Kind = raw.Kind,
            CreatedAt = Unix(now),
            LastCopiedAt = Unix(now),
        };

        switch (raw.Kind)
        {
            case ClipboardKind.Text:
                item.Text = raw.Text;
                item.ByteLength = Encoding.UTF8.GetByteCount(raw.Text ?? "");
                return item;

            case ClipboardKind.FileUrls:
                item.FilePaths = raw.Files;
                return item;

            case ClipboardKind.Image:
                // 转码放在这里（剪贴板已关闭），DIB 补 BMP 头再交给 WPF 解码
                var png = raw.ImageIsDib ? DibToPng(raw.Image) : raw.Image;
                if (png is null || SizeOf(png) is not { } size) return null;
                item.MediaSha256 = _store.SaveImage(png);
                item.PixelWidth = size.Width;
                item.PixelHeight = size.Height;
                item.ByteLength = png.Length;
                return item;

            default:
                return null;
        }
    }

    /// <summary>
    /// 图片：优先读注册格式 PNG（无损、无需转码），没有就拷原始 CF_DIB 字节。
    /// 注意这里**不做转码** —— 转码很贵，必须等剪贴板关闭之后再做。
    /// </summary>
    private static (byte[] Bytes, bool IsDib)? ReadImage()
    {
        var pngFormat = NativeMethods.RegisterClipboardFormat("PNG");
        if (pngFormat != 0 && NativeMethods.IsClipboardFormatAvailable(pngFormat))
        {
            var handle = NativeMethods.GetClipboardData(pngFormat);
            if (handle != IntPtr.Zero && ReadGlobal(handle) is { Length: > 0 } png) return (png, false);
        }

        if (!NativeMethods.IsClipboardFormatAvailable(NativeMethods.CfDib)) return null;
        var dib = NativeMethods.GetClipboardData(NativeMethods.CfDib);
        if (dib == IntPtr.Zero) return null;

        return ReadGlobal(dib) is { Length: >= 40 } bytes ? (bytes, true) : null;
    }

    /// <summary>
    /// CF_DIB 是裸的 BITMAPINFO（没有 BMP 文件头）。这里补一个 14 字节文件头交给 WPF 解码，
    /// 让系统去处理调色板、位深、自底向上、BI_BITFIELDS 这些细节 —— 自己算步长很容易出错。
    /// </summary>
    internal static byte[]? DibToPng(byte[]? dib)
    {
        if (dib is not { Length: >= 40 }) return null;

        try
        {
            var headerSize = BitConverter.ToInt32(dib, 0);
            var bitCount = BitConverter.ToUInt16(dib, 14);
            var compression = BitConverter.ToUInt32(dib, 16);
            var colorsUsed = BitConverter.ToUInt32(dib, 32);

            var paletteEntries = bitCount <= 8 ? (colorsUsed == 0 ? 1u << bitCount : colorsUsed) : 0u;
            var masksSize = compression == 3 ? 12 : 0;   // BI_BITFIELDS
            var pixelOffset = 14 + headerSize + (int)paletteEntries * 4 + masksSize;

            var buffer = new byte[14 + dib.Length];
            buffer[0] = (byte)'B';
            buffer[1] = (byte)'M';
            WriteInt32(buffer, 2, buffer.Length);
            WriteInt32(buffer, 10, pixelOffset);
            Buffer.BlockCopy(dib, 0, buffer, 14, dib.Length);

            using var input = new MemoryStream(buffer);
            var frame = BitmapFrame.Create(input, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
            using var output = new MemoryStream();
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(frame);
            encoder.Save(output);
            return output.ToArray();
        }
        catch
        {
            // 解不了就当没有图片：宁可漏记一条，也不能因为一张怪图把采集弄崩
            return null;
        }
    }

    internal static (int Width, int Height)? SizeOf(byte[] png)
    {
        try
        {
            using var stream = new MemoryStream(png);
            var frame = BitmapFrame.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.OnLoad);
            return frame.PixelWidth > 0 ? (frame.PixelWidth, frame.PixelHeight) : null;
        }
        catch
        {
            return null;
        }
    }

    private static byte[]? ReadGlobal(IntPtr handle)
    {
        var pointer = NativeMethods.GlobalLock(handle);
        if (pointer == IntPtr.Zero) return null;
        try
        {
            var length = checked((int)NativeMethods.GlobalSize(handle).ToUInt64());
            if (length <= 0) return null;
            var buffer = new byte[length];
            Marshal.Copy(pointer, buffer, 0, length);
            return buffer;
        }
        finally
        {
            NativeMethods.GlobalUnlock(handle);
        }
    }

    private static string? ReadText()
    {
        var handle = NativeMethods.GetClipboardData(NativeMethods.CfText);
        if (handle == IntPtr.Zero) return null;

        var pointer = NativeMethods.GlobalLock(handle);
        if (pointer == IntPtr.Zero) return null;
        try
        {
            return Marshal.PtrToStringUni(pointer);
        }
        finally
        {
            NativeMethods.GlobalUnlock(handle);
        }
    }

    /// <summary>HDROP 由 DragQueryFile 自己解析，不要 GlobalLock。</summary>
    private static List<string> ReadFiles()
    {
        var result = new List<string>();
        var drop = NativeMethods.GetClipboardData(NativeMethods.CfHDrop);
        if (drop == IntPtr.Zero) return result;

        var count = NativeMethods.DragQueryFile(drop, 0xFFFFFFFF, null, 0);
        for (uint i = 0; i < count; i++)
        {
            var length = NativeMethods.DragQueryFile(drop, i, null, 0);
            if (length == 0) continue;

            var buffer = new char[length + 1];
            NativeMethods.DragQueryFile(drop, i, buffer, (uint)buffer.Length);
            result.Add(new string(buffer, 0, (int)length));
        }
        return result;
    }

    /// <summary>剪贴板被别的程序占着是常态（尤其连续复制时），短重试比直接放弃划算。</summary>
    private static bool OpenWithRetry(out string failure)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            if (NativeMethods.OpenClipboard(IntPtr.Zero))
            {
                failure = "";
                return true;
            }
            Thread.Sleep(20);
        }

        failure = "剪贴板被其它程序占用";
        return false;
    }

    private static string? ForegroundProcessName()
    {
        var window = NativeMethods.GetForegroundWindow();
        if (window == IntPtr.Zero) return null;

        NativeMethods.GetWindowThreadProcessId(window, out var pid);
        if (pid == 0) return null;

        try
        {
            return Process.GetProcessById((int)pid).ProcessName;
        }
        catch
        {
            // 进程可能已经退出，取不到来源不影响记录内容
            return null;
        }
    }

    private static double Unix(DateTimeOffset time) => time.ToUnixTimeMilliseconds() / 1000.0;

    private static void WriteInt32(byte[] buffer, int offset, int value)
    {
        buffer[offset] = (byte)value;
        buffer[offset + 1] = (byte)(value >> 8);
        buffer[offset + 2] = (byte)(value >> 16);
        buffer[offset + 3] = (byte)(value >> 24);
    }
}
