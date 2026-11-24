import CodevisorCore
import Foundation
import TranscriptKit
import UniformTypeIdentifiers

public enum AttachmentMediaKind: Equatable, Sendable {
  case image
  case video
  case pdf
  case file

  public init(file: PreviewFile) {
    self.init(name: file.name, mimeType: file.mimeType, kind: file.kind)
  }

  public init(name: String, mimeType: String, kind: Attachment.Kind) {
    let lowered = mimeType.lowercased()
    if kind == .image || lowered.hasPrefix("image/") {
      self = .image
    } else if lowered == "application/pdf" || name.lowercased().hasSuffix(".pdf") {
      self = .pdf
    } else if attachmentIsVideo(name: name, mimeType: mimeType) {
      self = .video
    } else {
      self = .file
    }
  }
}

public func attachmentContentType(name: String, mimeType: String) -> UTType {
  if let type = UTType(mimeType: mimeType), type != .data { return type }
  let pathExtension = (name as NSString).pathExtension
  if !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) { return type }
  return .data
}
