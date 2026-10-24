using Toolbox.Core.Capture;
using Xunit;

namespace Toolbox.Core.Tests;

public sealed class MosaicTests
{
    private const int W = 4, H = 4, Bpp = 4;

    /// <summary>4x4 Bgra32，全部白色；再按 (x,y)->color 覆盖指定像素。</summary>
    private static byte[] Build(params ((int X, int Y), byte B, byte G, byte R)[] overrides)
    {
        var pixels = new byte[W * H * Bpp];
        Array.Fill(pixels, (byte)255);
        foreach (var ((x, y), b, g, r) in overrides)
        {
            var i = (y * W + x) * Bpp;
            pixels[i] = b;
            pixels[i + 1] = g;
            pixels[i + 2] = r;
        }
        return pixels;
    }

    private static byte PixelAt(byte[] pixels, int x, int y, int channel) =>
        pixels[(y * W + x) * Bpp + channel];

    [Fact]
    public void SinglePixelRectWithUnitBlockKeepsItsOwnAverage()
    {
        var pixels = Build(((0, 0), 10, 20, 30));

        var result = Mosaic.Apply(pixels, W, H, Bpp, 0, 0, 1, 1, 1);

        Assert.Equal(10, PixelAt(result, 0, 0, 0));
        Assert.Equal(20, PixelAt(result, 0, 0, 1));
        Assert.Equal(30, PixelAt(result, 0, 0, 2));
        Assert.Equal(255, PixelAt(result, 3, 3, 0));   // 其余像素不受影响
    }

    /// <summary>块内 1 黑 3 白 -> 平均 191，块内所有像素都变成这个平均色。</summary>
    [Fact]
    public void BlockAveragesItsPixels()
    {
        var pixels = Build(((0, 0), 0, 0, 0));

        var result = Mosaic.Apply(pixels, W, H, Bpp, 0, 0, 4, 4, 2);

        // 块(0,0) 含 4 像素：1 黑 3 白 -> 每通道 255*3/4 = 191
        Assert.Equal(191, PixelAt(result, 0, 0, 0));
        Assert.Equal(191, PixelAt(result, 1, 1, 2));
        // 块(1,1) 全白 -> 仍是白
        Assert.Equal(255, PixelAt(result, 3, 3, 0));
    }

    /// <summary>
    /// 块对齐到 blockSize 网格，且**平均值只由选区内像素决定**：
    /// rect 只含 (1,1) 黑点，块 (0,0) 与 rect 的交集就只有这一个像素 -> 平均 = 黑。
    /// rect 外的 (0,0) 白点不参与平均，也保持不变。
    /// </summary>
    [Fact]
    public void BlockAverageOnlyCountsPixelsInsideTheRect()
    {
        var pixels = Build(((1, 1), 0, 0, 0));

        var result = Mosaic.Apply(pixels, W, H, Bpp, 1, 1, 1, 1, 2);

        Assert.Equal(0, PixelAt(result, 1, 1, 0));
        Assert.Equal(255, PixelAt(result, 0, 0, 0));   // rect 外不动
    }

    [Fact]
    public void RectIsClampedToImage()
    {
        var pixels = Build();
        var result = Mosaic.Apply(pixels, W, H, Bpp, 2, 2, 100, 100, 3);
        Assert.Equal(pixels.Length, result.Length);
        // 越界部分不存在可写像素，(3,3) 保持白
        Assert.Equal(255, PixelAt(result, 3, 3, 0));
    }

    [Fact]
    public void EmptyRectReturnsUnchanged()
    {
        var pixels = Build(((0, 0), 0, 0, 0));
        var result = Mosaic.Apply(pixels, W, H, Bpp, 3, 3, 0, 5, 2);
        Assert.Equal(pixels, result);
    }

    [Fact]
    public void InvalidBlockSizeThrows()
    {
        Assert.Throws<ArgumentException>(() =>
            Mosaic.Apply(Build(), W, H, Bpp, 0, 0, 4, 4, 0));
    }
}
