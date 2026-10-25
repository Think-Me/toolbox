using Xunit;
using Toolbox.Core.Capture;

namespace Toolbox.Core.Tests;

public sealed class SelectionSnappingTests
{
    private static readonly SnapRect Screen = new(0, 0, 1000, 800);

    private static (double[] Xs, double[] Ys) Targets(params SnapRect[] windows) =>
        SelectionSnapping.Targets(windows, Screen);

    [Fact]
    public void TargetsIncludeWindowEdgesClippedToScreen()
    {
        var (xs, ys) = Targets(new SnapRect(100, 50, 300, 200));

        Assert.Contains(100.0, xs);
        Assert.Contains(400.0, xs);
        Assert.Contains(50.0, ys);
        Assert.Contains(250.0, ys);
        // 屏幕边界也在候选里
        Assert.Contains(0.0, xs);
        Assert.Contains(1000.0, xs);
    }

    [Fact]
    public void WindowOutsideScreenContributesNothing()
    {
        var (xs, ys) = Targets(new SnapRect(-500, -500, 100, 100));

        Assert.Equal([0.0, 1000.0], xs);
        Assert.Equal([0.0, 800.0], ys);
    }

    [Fact]
    public void CrossScreenWindowOnlyContributesTheOnScreenPart()
    {
        // 窗口左半在屏外：只有 0..200 这段边界参与
        var (xs, ys) = Targets(new SnapRect(-100, 100, 300, 200));

        Assert.Contains(0.0, xs);
        Assert.Contains(200.0, xs);
        Assert.DoesNotContain(-100.0, xs);
        Assert.Contains(100.0, ys);
    }

    [Fact]
    public void EdgeWithinToleranceSnaps()
    {
        var targets = Targets(new SnapRect(100, 100, 300, 200));

        // 左边 104 距窗口左边 100 差 4 < 6：吸上
        var snapped = SelectionSnapping.Snap(SnapRect.FromPoints(104, 200, 500, 400), targets);
        Assert.Equal(100, snapped.Rect.Left);
        Assert.Contains(SnapEdge.Left, snapped.SnappedEdges);
        // 右边离任何候选线都远：不动
        Assert.Equal(500, snapped.Rect.Right);
        Assert.DoesNotContain(SnapEdge.Right, snapped.SnappedEdges);
    }

    [Fact]
    public void EdgeBeyondToleranceDoesNotSnap()
    {
        var targets = Targets(new SnapRect(100, 100, 300, 200));

        // 四条边都离候选线超过 6pt（窗口占 x:100-400, y:100-300；屏边 0/1000 与 0/800）
        var snapped = SelectionSnapping.Snap(SnapRect.FromPoints(120, 350, 500, 450), targets);

        Assert.Equal(120, snapped.Rect.Left);
        Assert.Empty(snapped.SnappedEdges);
    }

    /// <summary>两条对边互吸时必须守住最小尺寸，不能吸成负宽。</summary>
    [Fact]
    public void OpposingEdgesNeverCollapseBelowMinSize()
    {
        // 候选线 x=100（窗口左边）；选区只有 1.5 宽且贴着这条线：
        // 左边吸 100，右边 102 距 100 只有 2 < 6 也想吸，但守卫（>= minX + 1）必须拦住
        var targets = Targets(new SnapRect(100, 0, 300, 100));

        var snapped = SelectionSnapping.Snap(new SnapRect(100.5, 0, 1.5, 100), targets);

        Assert.True(snapped.Rect.Width >= SelectionSnapping.MinSize);
        Assert.Equal(100, snapped.Rect.Left);
        Assert.Contains(SnapEdge.Left, snapped.SnappedEdges);
        Assert.DoesNotContain(SnapEdge.Right, snapped.SnappedEdges);
    }

    [Fact]
    public void TieBreaksToTheSmallerCandidate()
    {
        // 499 和 501 都距 500 为 1：取较小者
        var targets = Targets(new SnapRect(499, 0, 2, 100));

        var snapped = SelectionSnapping.Snap(SnapRect.FromPoints(500, 0, 600, 100), targets);

        Assert.Equal(499, snapped.Rect.Left);
    }

    [Fact]
    public void TopmostWindowContainingReturnsFirstMatch()
    {
        // 从前到后：小窗在上层
        SnapRect[] windows = [new SnapRect(200, 200, 100, 100), new SnapRect(0, 0, 500, 500)];

        var hit = SelectionSnapping.TopmostWindowContaining(250, 250, windows);
        Assert.Equal(windows[0], hit);

        var miss = SelectionSnapping.TopmostWindowContaining(600, 600, windows);
        Assert.Null(miss);
    }
}
