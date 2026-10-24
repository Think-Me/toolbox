namespace Toolbox.Core.Capture;

/// <summary>像素坐标（虚拟桌面原点可能为负，多显示器时很常见）。</summary>
public readonly record struct PixelRect(int X, int Y, int Width, int Height)
{
    public bool IsEmpty => Width <= 0 || Height <= 0;
    public int Right => X + Width;
    public int Bottom => Y + Height;

    public static PixelRect FromPoints(int x1, int y1, int x2, int y2)
    {
        var left = Math.Min(x1, x2);
        var top = Math.Min(y1, y2);
        return new PixelRect(left, top, Math.Abs(x2 - x1), Math.Abs(y2 - y1));
    }

    public PixelRect Normalize() => Width < 0 || Height < 0
        ? new PixelRect(Width < 0 ? X + Width : X, Height < 0 ? Y + Height : Y, Math.Abs(Width), Math.Abs(Height))
        : this;

    public PixelRect Intersect(PixelRect other)
    {
        var left = Math.Max(X, other.X);
        var top = Math.Max(Y, other.Y);
        var right = Math.Min(Right, other.Right);
        var bottom = Math.Min(Bottom, other.Bottom);
        return right <= left || bottom <= top ? default : new PixelRect(left, top, right - left, bottom - top);
    }

    public PixelRect Offset(int dx, int dy) => new(X + dx, Y + dy, Width, Height);

    public PixelRect Inflate(int dx, int dy) =>
        new(X - dx, Y - dy, Width + dx * 2, Height + dy * 2);

    public override string ToString() => $"{X},{Y} {Width}×{Height}";
}

public readonly record struct MonitorBounds(PixelRect Bounds, PixelRect WorkArea, bool IsPrimary);

public static class CaptureGeometry
{
    /// <summary>所有显示器边界的并集；截图遮罩要覆盖整个虚拟桌面。</summary>
    public static PixelRect VirtualDesktop(IEnumerable<MonitorBounds> monitors)
    {
        var list = monitors.ToList();
        if (list.Count == 0) return default;
        var left = list.Min(m => m.Bounds.X);
        var top = list.Min(m => m.Bounds.Y);
        var right = list.Max(m => m.Bounds.Right);
        var bottom = list.Max(m => m.Bounds.Bottom);
        return new PixelRect(left, top, right - left, bottom - top);
    }

    public static MonitorBounds? MonitorAt(IReadOnlyList<MonitorBounds> monitors, int x, int y)
    {
        foreach (var monitor in monitors)
        {
            if (x >= monitor.Bounds.X && x < monitor.Bounds.Right &&
                y >= monitor.Bounds.Y && y < monitor.Bounds.Bottom)
                return monitor;
        }
        return null;
    }

    /// <summary>选区小于 3px 视为误触（和 macOS 版阈值一致）。</summary>
    public static bool IsUsableSelection(PixelRect selection) =>
        !selection.IsEmpty && selection.Width >= 3 && selection.Height >= 3;

    /// <summary>马赛克块边长：选区越小块越小，保证至少 3×3 个块。</summary>
    public static int MosaicBlockSize(PixelRect selection, int preferred = 12)
    {
        if (selection.IsEmpty) return Math.Max(1, preferred);
        var limit = Math.Max(1, Math.Min(selection.Width, selection.Height) / 3);
        return Math.Clamp(preferred, 1, limit);
    }

    /// <summary>把截图里的像素矩形换算成 WPF DIP（PerMonitorV2 下每个显示器比例可能不同）。</summary>
    public static (double X, double Y, double Width, double Height) ToDips(PixelRect rect, double scaleX, double scaleY)
    {
        if (scaleX <= 0) scaleX = 1;
        if (scaleY <= 0) scaleY = 1;
        return (rect.X / scaleX, rect.Y / scaleY, rect.Width / scaleX, rect.Height / scaleY);
    }
}
