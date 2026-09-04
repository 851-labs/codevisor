import Foundation
import TranscriptKit

/// Resolves paths on the server without expanding ~ against the client machine.
public enum MarkdownDocumentPath {
  public static func resolve(_ target: String, relativeTo directory: String) -> String? {
    let target = target.replacingOccurrences(
      of: #":\d+(?::\d+)?$"#, with: "", options: .regularExpression
    )
    guard var path = markdownLocalFilePath(target) else { return nil }
    if path.hasPrefix("file://") {
      guard let url = URL(string: path), url.isFileURL else { return nil }
      path = url.path
    } else {
      path = String(path.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }
    path = path.replacingOccurrences(of: #":\d+(?::\d+)?$"#, with: "", options: .regularExpression)
    guard !path.isEmpty else { return nil }
    if !path.hasPrefix("/"), !path.hasPrefix("~/") {
      path = directory + "/" + path
    }
    if path.hasPrefix("~/") {
      return "~" + URL(fileURLWithPath: "/" + path.dropFirst(2)).standardized.path
    }
    guard path.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: path).standardized.path
  }

  public static func isMarkdown(_ path: String) -> Bool {
    ["md", "markdown"].contains((path as NSString).pathExtension.lowercased())
  }
}
