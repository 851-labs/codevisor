import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct BrowserFavicon: @unchecked Sendable {
  static let maximumBytes = 131_072
  static let maximumSourcePixels = 256
  static let maximumPixels = 64

  let reference: String
  let png: Data
  let image: CGImage

  @concurrent
  static func decoding(_ png: Data) async -> BrowserFavicon? {
    guard png.count <= maximumBytes, let image = decodedImage(png) else { return nil }

    return BrowserFavicon(reference: reference(of: png), png: png, image: image)
  }

  @concurrent
  static func encoding(_ image: CGImage) async -> BrowserFavicon? {
    guard fits(width: image.width, height: image.height, within: maximumSourcePixels),
      let png = encodedPNG(image), png.count <= maximumBytes
    else { return nil }

    return BrowserFavicon(reference: reference(of: png), png: png, image: image)
  }

  static func reference(of png: Data) -> String {
    SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
  }

  private static func decodedImage(_ png: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      CGImageSourceGetType(source) as String? == UTType.png.identifier,
      hasFaviconSize(source)
    else { return nil }

    return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
  }

  private static func hasFaviconSize(_ source: CGImageSource) -> Bool {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    guard let width = properties?[kCGImagePropertyPixelWidth] as? Int,
      let height = properties?[kCGImagePropertyPixelHeight] as? Int
    else { return false }

    return fits(width: width, height: height, within: maximumSourcePixels)
  }

  private static func fits(width: Int, height: Int, within limit: Int) -> Bool {
    (1...limit).contains(width) && (1...limit).contains(height)
  }

  private static var thumbnailOptions: CFDictionary {
    [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
      kCGImageSourceShouldCacheImmediately: true,
    ] as CFDictionary
  }

  private static func encodedPNG(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { return nil }

    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }
}
