using Xunit;
using Toolbox.Core.Capture;

namespace Toolbox.Core.Tests;

public sealed class AnnotationHitTestTests
{
    private static readonly SnapRect Rect = new(100, 100, 200, 100);

    [Fact]
    public void RectHitInsideAndWithTolerance()
    {
        Assert.True(AnnotationHitTest.HitRect(150, 150, Rect));
        // 在矩形外 3pt，容差 5：命中
        Assert.True(AnnotationHitTest.HitRect(97, 150, Rect, 5));
        // 在矩形外 3pt，零容差：不中
        Assert.False(AnnotationHitTest.HitRect(97, 150, Rect));
    }

    [Fact]
    public void EllipseHitFollowsTheOvalNotTheBoundingBox()
    {
        // 200x100 的矩形：角点 (110,105) 在外接框内但椭圆外
        Assert.False(AnnotationHitTest.HitEllipse(110, 105, Rect));
        // 中心命中
        Assert.True(AnnotationHitTest.HitEllipse(200, 150, Rect));
        // 椭圆底缘（y=200）外 4pt，容差 5：命中
        Assert.True(AnnotationHitTest.HitEllipse(200, 204, Rect, 5));
    }

    [Fact]
    public void PolylineHitMeasuresDistanceToTheSegment()
    {
        (double, double)[] line = [(0, 0), (100, 0)];

        // 线上方 2pt，容差 3：命中
        Assert.True(AnnotationHitTest.HitPolyline(50, -2, line, 3));
        // 线上方 5pt：不中
        Assert.False(AnnotationHitTest.HitPolyline(50, -5, line, 3));
        // 垂足落在线段外：取端点距离（150,0 到端点 (100,0) 是 50）
        Assert.False(AnnotationHitTest.HitPolyline(150, 0, line, 3));
        Assert.True(AnnotationHitTest.HitPolyline(103, 0, line, 3));
    }

    [Fact]
    public void NearestCornerOnlyGrabsWithinRadius()
    {
        // 左上角 (100,100)：偏 3pt，半径 5 命中 corner 0
        var hit = AnnotationHitTest.NearestCorner(103, 97, Rect, 5);
        Assert.Equal(0, hit!.Value.Corner);

        // 距所有角都远
        Assert.Null(AnnotationHitTest.NearestCorner(200, 150, Rect, 5));
    }

    [Fact]
    public void CornersEnumerateInClockwiseOrderFromTopLeft()
    {
        var corners = AnnotationHitTest.Corners(Rect).ToList();

        Assert.Equal(100, corners[0].Y);   // 左上
        Assert.Equal(300, corners[1].X);   // 右上
        Assert.Equal(200, corners[2].Y);   // 右下
        Assert.Equal(100, corners[3].X);   // 左下
    }
}
