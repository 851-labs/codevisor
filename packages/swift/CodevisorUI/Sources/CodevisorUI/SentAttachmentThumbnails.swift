import CodevisorCore
import ImageIO
import TranscriptKit

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// Thumbnails of images the user just sent, decoded from the composer's
/// local bytes the moment Send is pressed. A sent message's attachment
/// thumbnails read this synchronously, so the bubble flying out of the
/// composer shows its photos from its first frame instead of a placeholder
/// while the server copy loads.
@MainActor
public enum SentAttachmentThumbnails {
  private static let capacity = 16
  nonisolated private static let maxPixelSize = 480
  private static var images: [(fileId: String, image: OSImage)] = []

  /// Decodes each uploaded image attachment off the main thread.
  public static func prepare(_ attachments: [ComposerAttachment]) {
    for attachment in attachments where attachment.isImage {
      guard case let .uploaded(ref) = attachment.state,
        !images.contains(where: { $0.fileId == ref.fileId })
      else { continue }
      let data = attachment.localData
      let fileId = ref.fileId
      Task {
        guard
          let image = await Task.detached(priority: .userInitiated, operation: { decode(data) }).value?.image
        else { return }
        images.removeAll { $0.fileId == fileId }
        images.append((fileId, image))
        if images.count > capacity { images.removeFirst(images.count - capacity) }
      }
    }
  }

  public static func image(for file: PreviewFile) -> OSImage? {
    guard case let .attachment(fileId) = file.source else { return nil }
    return images.last { $0.fileId == fileId }?.image
  }

  nonisolated private static func decode(_ data: Data) -> AttachmentPreviewImage? {
    guard
      let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let pixels = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    else { return nil }
    #if canImport(AppKit)
      let image = NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height))
    #else
      let image = UIImage(cgImage: pixels)
    #endif
    return AttachmentPreviewImage(
      image: image, aspectRatio: CGFloat(pixels.width) / CGFloat(max(1, pixels.height)), version: "local")
  }
}
