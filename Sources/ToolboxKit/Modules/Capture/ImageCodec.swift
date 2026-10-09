import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 位图裁剪 / 降采样 / PNG 编解码。
/// 集中一处是因为这几件事在贴图、剪贴板缩略图、存盘三条路径上都要用，
/// 各自手写 `CGImageSource` 迟早出现"某条路径忘了钳边界"。
public enum ImageCodec {

    /// 按像素 rect 裁剪。越界部分**钳到图内**而不是返回 nil：
    /// 选区换算在浮点与取整之间可能溢出 1px，直接判失败会让用户觉得"偶尔截不出来"。
    /// 完全在图外才返回 nil。
    public static func crop(_ image: CGImage, pixelRect: CGRect) -> CGImage? {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = pixelRect.intersection(full)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return image.cropping(to: clamped.integral)
    }

    public static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// 只缩不放：maxPixel 大于原图时原样返回。
    /// 放大既没有信息增益，又会让贴图的最近邻像素观感消失。
    public static func downsample(_ data: Data, maxPixel: Int) -> Data? {
        guard let size = pixelSize(ofPNG: data), maxPixel > 0 else { return nil }
        let longest = max(size.width, size.height)
        if longest <= CGFloat(maxPixel) { return data }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: CGFloat(maxPixel),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        return png(thumb)
    }

    /// 只读头部尺寸，不解码整张图（列表缩略与去重要频繁问这个）。
    public static func pixelSize(ofPNG data: Data) -> CGSize? {
        guard !data.isEmpty,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double else { return nil }
        return CGSize(width: w, height: h)
    }
}
