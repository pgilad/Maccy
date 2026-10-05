import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image work with ImageIO. All functions are thread-safe and never decode
/// more pixels than they need.
public enum ImageProcessing {
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
  public static func pngData(from data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      return nil
    }
    return encode(image, as: .png)
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
