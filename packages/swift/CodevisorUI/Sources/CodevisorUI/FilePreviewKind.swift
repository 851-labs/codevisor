import Foundation
import UniformTypeIdentifiers

public enum FilePreviewKind: Equatable, Sendable {
  case image
  case video
  case document
  case none

  public init(name: String, mimeType: String? = nil) {
    let type = Self.contentType(name: name, mimeType: mimeType)
    if type.conforms(to: .image) {
      self = .image
    } else if type.conforms(to: .movie) {
      self = .video
    } else if Self.unpreviewable.contains(where: type.conforms(to:)) {
      self = .none
    } else {
      self = .document
    }
  }

  public static func hasSystemPreview(name: String) -> Bool {
    let type = contentType(name: name, mimeType: nil)
    return !type.isDynamic && type != .data
  }

  private static let unpreviewable: [UTType] = [.archive, .diskImage, .executable, .database]

  private static func contentType(name: String, mimeType: String?) -> UTType {
    let pathExtension = (name as NSString).pathExtension
    if !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) { return type }
    return mimeType.flatMap { UTType(mimeType: $0) } ?? .data
  }
}
