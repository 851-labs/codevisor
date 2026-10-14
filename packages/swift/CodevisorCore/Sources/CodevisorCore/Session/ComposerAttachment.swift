import Foundation
import UniformTypeIdentifiers

public struct ComposerAttachment: Identifiable, Equatable {
  public enum State: Equatable {
    case loading
    case uploading
    case uploaded(ServerAttachmentRef)
    case failed(String)
  }

  public let id: UUID
  public var name: String
  public var mimeType: String
  public var kind: Attachment.Kind
  public var fileURL: URL?
  public var sentPreviewData: Data?
  public var state: State

  public init(
    id: UUID,
    name: String,
    mimeType: String,
    kind: Attachment.Kind,
    fileURL: URL? = nil,
    sentPreviewData: Data? = nil,
    state: State
  ) {
    self.id = id
    self.name = name
    self.mimeType = mimeType
    self.kind = kind
    self.fileURL = fileURL
    self.sentPreviewData = sentPreviewData
    self.state = state
  }

  public var isImage: Bool { kind == .image }

  public var isPDF: Bool {
    mimeType == "application/pdf" || name.lowercased().hasSuffix(".pdf")
  }

  public var isVideo: Bool { attachmentIsVideo(name: name, mimeType: mimeType) }

  public var hasVisualPreview: Bool { isImage || isPDF || isVideo }
}

public func attachmentIsVideo(name: String, mimeType: String) -> Bool {
  if mimeType.lowercased().hasPrefix("video/") { return true }
  let pathExtension = (name as NSString).pathExtension
  guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) else {
    return false
  }
  return type.conforms(to: .movie)
}

public func decodePasteboardFileURL(_ data: Data) -> URL? {
  for encoding in [
    String.Encoding.utf8,
    .utf16,
    .utf16LittleEndian,
    .utf16BigEndian,
  ] {
    if let value = String(data: data, encoding: encoding),
      let url = pasteboardFileURL(from: value)
    {
      return url
    }
  }

  if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
    return url
  }

  if let archived = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data),
    let url = archived as URL?, url.isFileURL
  {
    return url
  }

  if let propertyList = try? PropertyListSerialization.propertyList(
    from: data,
    options: [],
    format: nil
  ), let url = pasteboardFileURL(fromPropertyList: propertyList) {
    return url
  }
  return nil
}

private func pasteboardFileURL(from value: String) -> URL? {
  let value = value.trimmingCharacters(
    in: .whitespacesAndNewlines.union(.controlCharacters)
  )
  if let url = URL(string: value), url.isFileURL {
    return url
  }
  if value.hasPrefix("/") {
    return URL(fileURLWithPath: value)
  }
  return nil
}

private func pasteboardFileURL(fromPropertyList value: Any) -> URL? {
  if let string = value as? String {
    return pasteboardFileURL(from: string)
  }
  if let values = value as? [Any] {
    return values.lazy.compactMap(pasteboardFileURL(fromPropertyList:)).first
  }
  if let values = value as? [String: Any] {
    return values.keys.sorted().lazy
      .compactMap { pasteboardFileURL(fromPropertyList: values[$0] as Any) }
      .first
  }
  return nil
}
