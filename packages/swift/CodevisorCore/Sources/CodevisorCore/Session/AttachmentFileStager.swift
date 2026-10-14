import Foundation
import UniformTypeIdentifiers

struct AttachmentFileStager {
  enum Result: Sendable {
    case staged(URL)
    case tooLarge
    case unreadable(String)
  }

  static func stageCopy(
    of url: URL, id: UUID, name: String, files: ComposerAttachmentFileStore, limitBytes: Int
  ) -> Result {
    if let size = ComposerAttachmentFileStore.byteCount(of: url), size > limitBytes {
      return .tooLarge
    }
    do {
      return .staged(try files.stageCopy(of: url, id: id, name: name))
    } catch {
      return .unreadable(String(describing: error))
    }
  }

  static func metadata(
    for url: URL
  ) -> (name: String, mimeType: String, kind: Attachment.Kind) {
    let type = UTType(filenameExtension: url.pathExtension)
    let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
    let kind: Attachment.Kind =
      (type?.conforms(to: .image) ?? false) || mimeType.hasPrefix("image/")
      ? .image
      : .file
    return (url.lastPathComponent, mimeType, kind)
  }

  static func tooLargeMessage(name: String, limitBytes: Int) -> String {
    "“\(name)” is too large to upload. Choose a file smaller than \(formattedUploadLimit(limitBytes))."
  }

  static func formattedUploadLimit(_ bytes: Int) -> String {
    let mebibyte = 1024 * 1024
    if bytes >= mebibyte { return "\(bytes / mebibyte) MB" }
    return "\(max(1, bytes / 1024)) KB"
  }

  @MainActor
  static func pastedImageNameDate() -> String {
    pastedImageFormatter.string(from: Date())
  }

  @MainActor
  private static let pastedImageFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return formatter
  }()
}
