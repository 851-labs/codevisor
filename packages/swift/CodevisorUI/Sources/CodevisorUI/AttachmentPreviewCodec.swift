import Foundation
import ImageIO

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

enum AttachmentPreviewCodec {
  nonisolated static func preview(data: Data, version: String) -> AttachmentPreviewImage? {
    guard
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let pixels = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 480,
        ] as CFDictionary)
    else { return nil as AttachmentPreviewImage? }
    let image = osImage(pixels)
    return AttachmentPreviewImage(
      image: image, aspectRatio: CGFloat(pixels.width) / CGFloat(pixels.height), version: version)
  }

  nonisolated static func pngData(for image: OSImage) -> Data? {
    #if canImport(AppKit)
      guard let tiff = image.tiffRepresentation,
        let representation = NSBitmapImageRep(data: tiff)
      else { return nil }
      return representation.representation(using: .png, properties: [:])
    #elseif canImport(UIKit)
      return image.pngData()
    #endif
  }

  nonisolated static func osImage(_ image: CGImage) -> OSImage {
    #if canImport(AppKit)
      NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    #else
      UIImage(cgImage: image)
    #endif
  }
}
