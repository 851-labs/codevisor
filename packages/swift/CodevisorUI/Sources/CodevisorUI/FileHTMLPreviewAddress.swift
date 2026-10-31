import Foundation
import TranscriptKit

struct FileHTMLPreviewAddress: Equatable, Sendable {
  static let scheme = "codevisor-file"
  private static let host = "preview"

  let page: String
  private let roots: [String]

  init(document path: String, rootPath: String) {
    if let attachment = markdownAttachmentFile(path) {
      page = "/" + attachment.name
      roots = []
    } else {
      page = path
      roots = [(path as NSString).deletingLastPathComponent, rootPath].filter { !$0.isEmpty }
    }
  }

  var pageURL: URL { Self.url(for: page) }

  func isPage(_ url: URL) -> Bool { Self.path(of: url) == page }

  func allows(_ path: String) -> Bool {
    path == page || roots.contains { Self.path(path, isInside: $0) }
  }

  static func url(for path: String) -> URL {
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.path = path.hasPrefix("/") ? path : "/" + path
    return components.url!
  }

  static func path(of url: URL) -> String? {
    guard url.scheme?.lowercased() == scheme, url.host() == host else { return nil }
    let path = url.path(percentEncoded: false)
    guard !hasDotSegments(path) else { return nil }
    return path.hasPrefix("/~/") ? String(path.dropFirst()) : path
  }

  private static func hasDotSegments(_ path: String) -> Bool {
    path.split(separator: "/").contains { $0 == "." || $0 == ".." }
  }

  private static func path(_ path: String, isInside root: String) -> Bool {
    path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
  }
}
