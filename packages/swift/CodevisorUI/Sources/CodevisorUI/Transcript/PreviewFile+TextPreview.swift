import CodeHighlighter
import Foundation
import TranscriptKit
import UniformTypeIdentifiers

extension PreviewFile {
  public var showsTextPreview: Bool {
    guard kind == .file else { return false }
    if highlightLanguage != nil { return true }
    guard let type = declaredType else { return true }
    return type.conforms(to: .text) || type.isDynamic || type == .data
  }

  var highlightLanguage: String? { CodeHighlighter.language(forPath: name) }

  var isPatch: Bool { highlightLanguage == Self.diffLanguage }

  private static let diffLanguage = "diff"

  private var declaredType: UTType? {
    let pathExtension = (name as NSString).pathExtension
    return UTType(filenameExtension: pathExtension) ?? UTType(mimeType: mimeType)
  }
}
