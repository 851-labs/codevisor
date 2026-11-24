import CodevisorCore
import Foundation
import TranscriptKit
import UniformTypeIdentifiers

public enum FileDocumentLocation {
  public static func resolve(_ target: String, relativeTo directory: String) -> String? {
    if markdownAttachmentFile(target) != nil { return target }
    guard let path = MarkdownDocumentPath.resolve(target, relativeTo: directory) else { return nil }
    return target.hasSuffix("/") && !path.hasSuffix("/") ? path + "/" : path
  }

  static func navigationTarget(_ target: String, relativeTo directory: String) -> String? {
    guard let path = resolve(target, relativeTo: directory) else { return nil }
    guard markdownAttachmentFile(path) == nil, let line = line(target) else { return path }
    return path + "#L\(line)"
  }

  public static func name(_ target: String) -> String {
    if target.hasSuffix("/") { return "Open File" }
    if let device = FileDeviceLocation(target) { return device.name }
    return markdownAttachmentFile(target)?.name ?? (target as NSString).lastPathComponent
  }

  public static func target(for file: PreviewFile) -> String {
    switch file.source {
    case let .serverPath(path), let .pendingCapture(path): return path
    case let .attachment(fileId):
      var components = URLComponents(string: "https://attachments.codevisor.invalid/")!
      components.path = "/" + fileId
      components.queryItems = [URLQueryItem(name: "name", value: typedName(file.name, mimeType: file.mimeType))]
      return components.string!
    }
  }

  static func typedName(_ name: String, mimeType: String) -> String {
    guard (name as NSString).pathExtension.isEmpty,
      let inferred = UTType(mimeType: mimeType)?.preferredFilenameExtension
    else { return name }
    return "\(name).\(inferred)"
  }

  public static func isHTML(_ path: String) -> Bool {
    ["html", "htm"].contains((path as NSString).pathExtension.lowercased())
  }

  public static func hasPreview(_ path: String) -> Bool { MarkdownDocumentPath.isMarkdown(path) || isHTML(path) }

  public static func opensRendered(_ target: String) -> Bool {
    guard line(target) == nil, let path = resolve(target, relativeTo: "/") else { return false }
    return hasPreview(name(path))
  }

  public static func line(_ target: String) -> Int? {
    guard let range = target.range(of: #"(?::\d+(?::\d+)?|#L\d+(?:-L?\d+)?)$"#, options: .regularExpression) else {
      return nil
    }
    return Int(target[range].drop(while: { !$0.isNumber }).prefix(while: \.isNumber))
  }

  public static func data(path: String, client: any CodevisorServerClienting) async throws -> Data {
    if let device = FileDeviceLocation(path) { return try await device.data() }
    if let file = markdownAttachmentFile(path), case let .attachment(id) = file.source {
      return try await client.fileData(id: id)
    }
    return try await client.documentData(path: path)
  }

  static func read(path: String, client: any CodevisorServerClienting) async throws -> ServerFileDocument {
    guard isSavedCopy(path) else { return try await client.readDocument(path: path) }
    let bytes = try await data(path: path, client: client)
    return ServerFileDocument(
      path: path, content: text(in: bytes), version: "saved-copy", size: bytes.count, writable: false,
      reason: savedCopyReason(path))
  }

  static func isSavedCopy(_ path: String) -> Bool {
    markdownAttachmentFile(path) != nil || FileDeviceLocation(path) != nil
  }

  private static func savedCopyReason(_ path: String) -> String {
    if FileDeviceLocation(path) != nil { return "This file has not been sent yet and is read-only." }
    return "This attachment is a saved copy and is read-only."
  }

  private static let textByteLimit = 4 * 1024 * 1024

  private static func text(in bytes: Data) -> String? {
    guard bytes.count <= textByteLimit, !bytes.contains(0) else { return nil }
    return String(data: bytes, encoding: .utf8)
  }
}
