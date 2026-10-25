namespace Toolbox.Core.Capture;

/// <summary>DIP 矩形（遮罩视图坐标系，左上原点）。只给吸附用，别和像素类型混。</summary>
public readonly record struct SnapRect(double X, double Y, double Width, double Height)
{
    public double Left => X;
    public double Top => Y;
    public double Right => X + Width;
    public double Bottom => Y + Height;

    public static SnapRect FromPoints(double x1, double y1, double x2, double y2) =>
        new(Math.Min(x1, x2), Math.Min(y1, y2), Math.Abs(x2 - x1), Math.Abs(y2 - y1));
}

public enum SnapEdge
{
    Left,
    Right,
    Top,
    Bottom,
}

/// <summary>吸附结果：修正后的矩形 + 吸上了哪几条边（画辅助线用）。</summary>
public sealed record SnappedSelection(SnapRect Rect, IReadOnlyCollection<SnapEdge> SnappedEdges)
{
    public bool HasSnaps => SnappedEdges.Count > 0;
}

/// <summary>
/// 选区边缘吸附（移植 macOS SelectionSnapping）。
/// 候选线 = 可见窗口的边缘（裁剪到本屏）+ 屏幕自身边界。
/// </summary>
public static class SelectionSnapping
{
    /// <summary>6pt：再小咬合感不明显，再大难以拖出精确小区域。</summary>
    public const double DefaultTolerance = 6;

    /// <summary>吸附后仍要保证的最小尺寸，防止两条对边互吸成零宽/负宽。</summary>
    public const double MinSize = 1;

    /// <summary>
    /// 汇总吸附线。窗口矩形按"从前到后"传入；跨屏窗口只取落在本屏内的那部分边界。
    /// </summary>
    public static (double[] Xs, double[] Ys) Targets(IReadOnlyList<SnapRect> windows, SnapRect screen)
    {
        var xs = new List<double> { screen.Left, screen.Right };
        var ys = new List<double> { screen.Top, screen.Bottom };
        foreach (var window in windows)
        {
            var left = Math.Max(window.Left, screen.Left);
            var top = Math.Max(window.Top, screen.Top);
            var right = Math.Min(window.Right, screen.Right);
            var bottom = Math.Min(window.Bottom, screen.Bottom);
            if (right <= left || bottom <= top) continue;   // 完全在屏外
            xs.Add(left);
            xs.Add(right);
            ys.Add(top);
            ys.Add(bottom);
        }

        return (xs.Distinct().OrderBy(v => v).ToArray(), ys.Distinct().OrderBy(v => v).ToArray());
    }

    public static SnappedSelection Snap(SnapRect rect, (double[] Xs, double[] Ys) targets,
                                        double tolerance = DefaultTolerance)
    {
        var minX = rect.Left;
        var maxX = rect.Right;
        var minY = rect.Top;
        var maxY = rect.Bottom;
        var edges = new List<SnapEdge>();

        // 左右/上下分别处理，且后一条边要用**已更新**的前一条边做守卫：
        // 否则两边界互吸可能把选区吸成负宽，后续裁剪与贴图会拿到畸形矩形。
        if (Nearest(targets.Xs, minX, tolerance) is { } left && left <= maxX - MinSize)
        {
            minX = left;
            edges.Add(SnapEdge.Left);
        }
        if (Nearest(targets.Xs, maxX, tolerance) is { } right && right >= minX + MinSize)
        {
            maxX = right;
            edges.Add(SnapEdge.Right);
        }
        if (Nearest(targets.Ys, minY, tolerance) is { } top && top <= maxY - MinSize)
        {
            minY = top;
            edges.Add(SnapEdge.Top);
        }
        if (Nearest(targets.Ys, maxY, tolerance) is { } bottom && bottom >= minY + MinSize)
        {
            maxY = bottom;
            edges.Add(SnapEdge.Bottom);
        }

        var outRect = SnapRect.FromPoints(minX, minY, maxX, maxY);
        if (outRect.Width < MinSize) outRect = outRect with { Width = MinSize };
        if (outRect.Height < MinSize) outRect = outRect with { Height = MinSize };
        return new SnappedSelection(outRect, edges);
    }

    /// <summary>悬停命中：候选必须按"从前到后"传入，返回第一个包含该点的。</summary>
    public static SnapRect? TopmostWindowContaining(double x, double y, IReadOnlyList<SnapRect> ordered)
    {
        foreach (var window in ordered)
            if (window.Width > 0 && window.Height > 0 &&
                x >= window.Left && x <= window.Right && y >= window.Top && y <= window.Bottom)
                return window;
        return null;
    }

    /// <summary>等距时取较小值，保证结果确定（否则同一坐标两次算可能吸到不同线上）。</summary>
    private static double? Nearest(double[] values, double target, double tolerance)
    {
        double? best = null;
        var bestDist = double.MaxValue;
        foreach (var candidate in values)
        {
            var dist = Math.Abs(candidate - target);
            if (dist > tolerance) continue;
            if (dist < bestDist || (dist == bestDist && candidate < best))
            {
                best = candidate;
                bestDist = dist;
            }
        }
        return best;
    }
}
