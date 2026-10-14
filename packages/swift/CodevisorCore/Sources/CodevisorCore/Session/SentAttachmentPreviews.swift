import Foundation
import ImageIO

@MainActor
final class SentAttachmentPreviews {
  private static let capacity = 8
  nonisolated private static let maxPixelSize = 960
  private var entries: [(fileId: String, data: Data)] = []

  func remember(_ preview: Data, for fileId: String) {
    entries.removeAll { $0.fileId == fileId }
    entries.append((fileId, preview))
    if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
  }

  func preview(for fileId: String) -> Data? {
    entries.last { $0.fileId == fileId }?.data
  }

  nonisolated static func encodePreview(of fileURL: URL) -> Data? {
    guard
      let source = CGImageSourceCreateWithURL(fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    else { return nil }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }
}
