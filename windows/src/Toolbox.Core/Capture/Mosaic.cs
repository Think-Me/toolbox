namespace Toolbox.Core.Capture;

/// <summary>
/// 块平均马赛克（Bgra32/Bgr32 像素）。纯像素数学，与 UI 解耦，可单测。
/// 每个块的颜色 = 块内像素的平均值，写回块内**与选区相交**的每一个像素。
/// </summary>
public static class Mosaic
{
    public static byte[] Apply(byte[] pixels, int width, int height, int bytesPerPixel,
                               int rectX, int rectY, int rectWidth, int rectHeight, int blockSize)
    {
        if (bytesPerPixel is not (3 or 4)) throw new ArgumentException("只支持 3/4 字节像素", nameof(bytesPerPixel));
        if (blockSize <= 0) throw new ArgumentException("块大小必须为正", nameof(blockSize));

        var result = new byte[pixels.Length];
        Array.Copy(pixels, result, pixels.Length);

        var left = Math.Clamp(rectX, 0, width);
        var top = Math.Clamp(rectY, 0, height);
        var right = Math.Clamp(rectX + rectWidth, 0, width);
        var bottom = Math.Clamp(rectY + rectHeight, 0, height);
        if (left >= right || top >= bottom) return result;

        for (var blockY = top / blockSize * blockSize; blockY < bottom; blockY += blockSize)
        for (var blockX = left / blockSize * blockSize; blockX < right; blockX += blockSize)
        {
            ApplyBlock(result, width, height, bytesPerPixel,
                Math.Max(blockX, left), Math.Max(blockY, top),
                Math.Min(blockX + blockSize, right), Math.Min(blockY + blockSize, bottom));
        }
        return result;
    }

    private static void ApplyBlock(byte[] pixels, int width, int height, int bpp,
                                   int left, int top, int right, int bottom)
    {
        double b = 0, g = 0, r = 0, count = 0;
        for (var y = top; y < bottom; y++)
        {
            var offset = y * width * bpp;
            for (var x = left; x < right; x++)
            {
                var i = offset + x * bpp;
                b += pixels[i];
                g += pixels[i + 1];
                r += pixels[i + 2];
                count++;
            }
        }
        if (count == 0) return;

        var (bb, gg, rr) = ((byte)(b / count), (byte)(g / count), (byte)(r / count));
        for (var y = top; y < bottom; y++)
        {
            var offset = y * width * bpp;
            for (var x = left; x < right; x++)
            {
                var i = offset + x * bpp;
                pixels[i] = bb;
                pixels[i + 1] = gg;
                pixels[i + 2] = rr;
            }
        }
    }
}
