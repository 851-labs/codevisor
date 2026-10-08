import Foundation
import UniformTypeIdentifiers

/// A file attached to a conversation message, referencing bytes stored server-side
/// (`GET /v1/files/:id`).
public struct Attachment: Identifiable, Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    case image
    case file
  }

  public let fileId: String
  public var name: String
  public var mimeType: String
  public var sizeBytes: Int
  public var kind: Kind

  public var id: String { fileId }

  public init(fileId: String, name: String, mimeType: String, sizeBytes: Int, kind: Kind) {
    self.fileId = fileId
    self.name = name
    self.mimeType = mimeType
    self.sizeBytes = sizeBytes
    self.kind = kind
  }
}

/// A file the transcript can preview. Uploaded attachments and live paths on
/// the session's server share one presentation path while retaining different
/// fetch semantics.
public struct PreviewFile: Identifiable, Sendable, Equatable {
  public enum Source: Sendable, Equatable, Hashable {
    case attachment(fileId: String)
    case serverPath(String)

    public var cacheKey: String {
      switch self {
      case let .attachment(fileId): "attachment:\(fileId)"
      case let .serverPath(path): "server-path:\(path)"
      }
    }
  }

  public let source: Source
  public var name: String
  public var mimeType: String
  public var kind: Attachment.Kind

  public var id: String { source.cacheKey }

  public init(source: Source, name: String, mimeType: String, kind: Attachment.Kind) {
    self.source = source
    self.name = name
    self.mimeType = mimeType
    self.kind = kind
  }

  public init(attachment: Attachment) {
    self.init(
      source: .attachment(fileId: attachment.fileId),
      name: attachment.name,
      mimeType: attachment.mimeType,
      kind: attachment.kind
    )
  }

  public init(serverPath rawPath: String) {
    let decoded = rawPath.removingPercentEncoding ?? rawPath
    let path: String
    if decoded.hasPrefix("file://"), let url = URL(string: decoded), url.isFileURL {
      path = url.path
    } else {
      path = decoded
    }
    let displayPath =
      path
      .replacingOccurrences(of: #"#L\d+(?:-L?\d+)?$"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #":\d+(?::\d+)?$"#, with: "", options: .regularExpression)
    let candidateName = URL(fileURLWithPath: displayPath).lastPathComponent
    let name = candidateName.isEmpty ? "File" : candidateName
    let pathExtension = (name as NSString).pathExtension
    let mimeType =
      UTType(filenameExtension: pathExtension)?.preferredMIMEType
      ?? "application/octet-stream"
    self.init(
      source: .serverPath(path),
      name: name,
      mimeType: mimeType,
      kind: mimeType.hasPrefix("image/") ? .image : .file
    )
  }
}
