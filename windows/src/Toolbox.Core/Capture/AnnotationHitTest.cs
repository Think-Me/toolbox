namespace Toolbox.Core.Capture;

/// <summary>
/// 标注命中测试的纯几何（移植 macOS AnnotationHitTest 的判定职责）。
/// 坐标一律是选区内 DIP；容差由调用方给（通常 = 线宽一半 + 手指余量）。
/// </summary>
public static class AnnotationHitTest
{
    /// <summary>点是否在矩形内（含 tolerance 外扩）。</summary>
    public static bool HitRect(double x, double y, SnapRect rect, double tolerance = 0) =>
        x >= rect.Left - tolerance && x <= rect.Right + tolerance &&
        y >= rect.Top - tolerance && y <= rect.Bottom + tolerance;

    /// <summary>点是否在椭圆内（把点缩进单位圆判断；tolerance 同样外扩）。</summary>
    public static bool HitEllipse(double x, double y, SnapRect rect, double tolerance = 0)
    {
        var width = rect.Width + tolerance * 2;
        var height = rect.Height + tolerance * 2;
        if (width <= 0 || height <= 0) return false;

        // (x,y) 相对中心，归一到单位圆；越界说明点在椭圆外
        var dx = (x - (rect.Left + rect.Width / 2)) / (width / 2);
        var dy = (y - (rect.Top + rect.Height / 2)) / (height / 2);
        return dx * dx + dy * dy <= 1;
    }

    /// <summary>点到折线（含箭头这类两段线）的距离是否在容差内。</summary>
    public static bool HitPolyline(double x, double y, IReadOnlyList<(double X, double Y)> points,
                                   double tolerance)
    {
        if (points.Count == 0) return false;
        if (points.Count == 1) return Distance2(x, y, points[0].X, points[0].Y) <= tolerance * tolerance;

        for (var i = 0; i < points.Count - 1; i++)
        {
            if (DistanceToSegment2(x, y, points[i], points[i + 1]) <= tolerance * tolerance)
                return true;
        }
        return false;
    }

    /// <summary>点在矩形边上（用于角柄/边柄命中）。</summary>
    public static (int Corner, double X, double Y)? NearestCorner(
        double x, double y, SnapRect rect, double grabRadius)
    {
        (int, double, double)? best = null;
        var bestDist = grabRadius * grabRadius;
        foreach (var (corner, cx, cy) in Corners(rect))
        {
            var dist = Distance2(x, y, cx, cy);
            if (dist <= grabRadius * grabRadius && dist < bestDist)
            {
                best = (corner, cx, cy);
                bestDist = dist;
            }
        }
        return best;
    }

    /// <summary>角序：0=左上 1=右上 2=右下 3=左下。</summary>
    public static IEnumerable<(int Corner, double X, double Y)> Corners(SnapRect rect)
    {
        yield return (0, rect.Left, rect.Top);
        yield return (1, rect.Right, rect.Top);
        yield return (2, rect.Right, rect.Bottom);
        yield return (3, rect.Left, rect.Bottom);
    }

    private static double Distance2(double x, double y, double px, double py)
    {
        var dx = x - px;
        var dy = y - py;
        return dx * dx + dy * dy;
    }

    private static double DistanceToSegment2(double x, double y,
                                             (double X, double Y) a, (double X, double Y) b)
    {
        var abX = b.X - a.X;
        var abY = b.Y - a.Y;
        var length2 = abX * abX + abY * abY;
        if (length2 <= 0) return Distance2(x, y, a.X, a.Y);

        // 投影参数钳到 [0,1]：垂足落在线段外时取端点
        var t = ((x - a.X) * abX + (y - a.Y) * abY) / length2;
        t = Math.Clamp(t, 0, 1);
        return Distance2(x, y, a.X + t * abX, a.Y + t * abY);
    }
}
