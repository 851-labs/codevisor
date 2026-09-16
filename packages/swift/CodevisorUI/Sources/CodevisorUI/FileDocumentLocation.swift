import CodevisorCore
import Foundation
import TranscriptKit

public enum FileDocumentLocation {
  public static func resolve(_ target: String, relativeTo directory: String) -> String? {
    if markdownAttachmentFile(target) != nil { return target }
    guard let path = MarkdownDocumentPath.resolve(target, relativeTo: directory) else { return nil }
    return target.hasSuffix("/") && !path.hasSuffix("/") ? path + "/" : path
  }

  /// Resolve a preview's relative link while retaining its cursor destination.
  static func navigationTarget(_ target: String, relativeTo directory: String) -> String? {
    guard let path = resolve(target, relativeTo: directory) else { return nil }
    guard markdownAttachmentFile(path) == nil, let line = line(target) else { return path }
    return path + "#L\(line)"
  }

  public static func name(_ target: String) -> String {
    if target.hasSuffix("/") { return "Open File" }
    return markdownAttachmentFile(target)?.name ?? (target as NSString).lastPathComponent
  }

  public static func target(for file: PreviewFile) -> String {
    switch file.source {
    case let .serverPath(path): return path
    case let .attachment(fileId):
      var components = URLComponents(string: "https://attachments.codevisor.invalid/")!
      components.path = "/" + fileId
      components.queryItems = [URLQueryItem(name: "name", value: file.name)]
      return components.string!
    }
  }

  public static func line(_ target: String) -> Int? {
    guard let range = target.range(of: #"(?::\d+(?::\d+)?|#L\d+(?:-L?\d+)?)$"#, options: .regularExpression) else {
      return nil
    }
    return Int(target[range].drop(while: { !$0.isNumber }).prefix(while: \.isNumber))
  }

  static func data(path: String, client: any CodevisorServerClienting) async throws -> Data {
    if let file = markdownAttachmentFile(path), case let .attachment(id) = file.source {
      return try await client.fileData(id: id)
    }
    return try await client.documentData(path: path)
  }

  static func read(path: String, client: any CodevisorServerClienting) async throws -> ServerFileDocument {
    guard markdownAttachmentFile(path) != nil else { return try await client.readDocument(path: path) }
    let bytes = try await data(path: path, client: client)
    let text = bytes.count <= 4 * 1024 * 1024 && !bytes.contains(0) ? String(data: bytes, encoding: .utf8) : nil
    return ServerFileDocument(
      path: path, content: text, version: "attachment", size: bytes.count, writable: false,
      reason: "This attachment is a saved copy and is read-only.")
  }
}
