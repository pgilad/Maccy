import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image work with ImageIO. All functions are thread-safe and never decode
/// more pixels than they need.
public enum ImageProcessing {
  /// The largest image that the TIFF-to-PNG conversion decodes: 25 megapixels, about
  /// 100 MB of pixels. The size limit of a copy counts encoded bytes, and a compressed
  /// TIFF of 2 MB can hold 100 megapixels (400 MB decoded).
  public static let maxConvertedPixelCount = 25_000_000

  /// The uniform type identifier of the image format, from the file header.
  public static func typeIdentifier(of data: Data) -> String? {
    CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType).map { $0 as String }
  }

  public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else {
      return nil
    }
    let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
    // Orientations 5–8 rotate the image by 90 degrees.
    return orientation >= 5 ? (height, width) : (width, height)
  }

  /// Decodes a reduced-size image. The full image is never in memory.
  public static func downsample(_ data: Data, maxPixelSize: Int) -> CGImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
      return nil
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  public static func thumbnailPNG(from data: Data, maxPixelSize: Int = 128) -> Data? {
    downsample(data, maxPixelSize: maxPixelSize).flatMap { encode($0, as: .png) }
  }

  /// Re-encodes an image (for example a large TIFF) as PNG. PNG is lossless.
  /// This decodes the full image, so it returns `nil` for an image with more than
  /// `maxPixelCount` pixels. The header gives the size without a decode.
  public static func pngData(from data: Data, maxPixelCount: Int = maxConvertedPixelCount) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          isWithinPixelLimit(width: width, height: height, maxPixelCount: maxPixelCount),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      return nil
    }
    return encode(image, as: .png)
  }

  /// A crafted header can give sizes whose product overflows `Int` and wraps to a
  /// negative number, which would pass a plain `<=` check.
  static func isWithinPixelLimit(width: Int, height: Int, maxPixelCount: Int) -> Bool {
    let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
    return width > 0 && height > 0 && !overflow && pixels <= maxPixelCount
  }

  public static func tiffData(from data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      return nil
    }
    return encode(image, as: .tiff)
  }

  public static func encode(_ image: CGImage, as type: UTType) -> Data? {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      return nil
    }
    return output as Data
  }
}
