import CodevisorCore
import ImageIO
import TranscriptKit

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

@MainActor
public enum SentAttachmentThumbnails {
  private static let capacity = 16
  nonisolated private static let maxPixelSize = 480
  private static var images: [(fileId: String, image: OSImage)] = []
  private static var aspectRatios: [(fileId: String, aspectRatio: CGFloat)] = []

  public static func prepare(_ attachments: [ComposerAttachment]) {
    for attachment in attachments where attachment.isImage {
      let fileId = attachment.sentFileID
      guard let data = attachment.sentPreviewData, !images.contains(where: { $0.fileId == fileId }) else { continue }
      remember(aspectRatio: headerAspectRatio(data), for: fileId)
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

  public static func aspectRatio(for file: PreviewFile) -> CGFloat? {
    let ids = knownFileIDs(for: file)
    return aspectRatios.last { ids.contains($0.fileId) }?.aspectRatio
  }

  private static func remember(aspectRatio: CGFloat?, for fileId: String) {
    guard let aspectRatio else { return }
    aspectRatios.removeAll { $0.fileId == fileId }
    aspectRatios.append((fileId, aspectRatio))
    if aspectRatios.count > capacity { aspectRatios.removeFirst(aspectRatios.count - capacity) }
  }

  nonisolated private static func headerAspectRatio(_ data: Data) -> CGFloat? {
    guard
      let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
      let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0
    else { return nil }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    return orientation >= 5 ? height / width : width / height
  }

  public static func image(for file: PreviewFile) -> OSImage? {
    let ids = knownFileIDs(for: file)
    return images.last { ids.contains($0.fileId) }?.image
  }

  private static func knownFileIDs(for file: PreviewFile) -> [String] {
    guard case let .attachment(fileId) = file.source else { return [] }
    return [fileId] + [SentAttachmentAliases.sentFileID(forUploaded: fileId)].compactMap(\.self)
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
