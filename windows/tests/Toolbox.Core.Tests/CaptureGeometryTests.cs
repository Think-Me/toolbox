using Toolbox.Core.Capture;
using Xunit;

namespace Toolbox.Core.Tests;

public sealed class CaptureGeometryTests
{
    [Fact]
    public void FromPointsNormalizesAnyDragDirection()
    {
        Assert.Equal(new PixelRect(10, 20, 30, 40), PixelRect.FromPoints(40, 60, 10, 20));
        Assert.Equal(new PixelRect(10, 20, 30, 40), PixelRect.FromPoints(10, 20, 40, 60));
        Assert.Equal(new PixelRect(10, 20, 30, 40), PixelRect.FromPoints(40, 20, 10, 60));
    }

    [Fact]
    public void VirtualDesktopUnionsNegativeOriginMonitors()
    {
        var monitors = new[]
        {
            new MonitorBounds(new PixelRect(0, 0, 1920, 1080), new PixelRect(0, 0, 1920, 1040), true),
            new MonitorBounds(new PixelRect(-2560, -200, 2560, 1440), new PixelRect(-2560, -200, 2560, 1400), false),
        };
        var desktop = CaptureGeometry.VirtualDesktop(monitors);
        Assert.Equal(new PixelRect(-2560, -200, 4480, 1440), desktop);
    }

    [Fact]
    public void MonitorAtHandlesNegativeCoordinates()
    {
        var monitors = new[]
        {
            new MonitorBounds(new PixelRect(0, 0, 1920, 1080), new PixelRect(0, 0, 1920, 1040), true),
            new MonitorBounds(new PixelRect(-1920, 0, 1920, 1080), new PixelRect(-1920, 0, 1920, 1040), false),
        };
        Assert.Equal(-1920, CaptureGeometry.MonitorAt(monitors, -100, 100)!.Value.Bounds.X);
        Assert.Equal(0, CaptureGeometry.MonitorAt(monitors, 100, 100)!.Value.Bounds.X);
        Assert.Null(CaptureGeometry.MonitorAt(monitors, 5000, 5000));
    }

    [Fact]
    public void TinySelectionsAreRejected()
    {
        Assert.False(CaptureGeometry.IsUsableSelection(new PixelRect(0, 0, 2, 100)));
        Assert.False(CaptureGeometry.IsUsableSelection(new PixelRect(0, 0, 100, 2)));
        Assert.True(CaptureGeometry.IsUsableSelection(new PixelRect(0, 0, 3, 3)));
    }

    [Fact]
    public void MosaicBlockShrinksForSmallSelections()
    {
        Assert.Equal(12, CaptureGeometry.MosaicBlockSize(new PixelRect(0, 0, 400, 400)));
        Assert.Equal(3, CaptureGeometry.MosaicBlockSize(new PixelRect(0, 0, 9, 9)));
        Assert.Equal(1, CaptureGeometry.MosaicBlockSize(new PixelRect(0, 0, 2, 2)));
    }

    [Fact]
    public void DipsRespectPerMonitorScale()
    {
        var (x, y, w, h) = CaptureGeometry.ToDips(new PixelRect(200, 100, 400, 200), 2, 2);
        Assert.Equal((100d, 50d, 200d, 100d), (x, y, w, h));
    }

    [Fact]
    public void IntersectAndInflateStayInsideDesktop()
    {
        var selection = new PixelRect(10, 10, 100, 100);
        Assert.Equal(new PixelRect(10, 10, 40, 40), selection.Intersect(new PixelRect(0, 0, 50, 50)));
        Assert.True(selection.Intersect(new PixelRect(500, 500, 10, 10)).IsEmpty);
        Assert.Equal(new PixelRect(5, 5, 110, 110), selection.Inflate(5, 5));
    }
}
