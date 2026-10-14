import ACPKit
import Foundation

public struct ReadFileOutput: Sendable, Equatable {
  public enum Content: Sendable, Equatable {
    case text(String)
    case media
  }

  public let path: String
  public let content: Content
}

extension ToolCall {
  public var readFileOutput: ReadFileOutput? {
    guard kind == .read, status != .failed, let path = readFilePath else { return nil }
    if Self.isMedia(path: path) { return ReadFileOutput(path: path, content: .media) }
    guard status == .completed, let text = readFileText else { return nil }
    return ReadFileOutput(path: path, content: .text(Self.fileText(text)))
  }

  private var readFilePath: String? {
    let input = ["file_path", "filePath", "path"].lazy.compactMap { self.rawInput?[$0]?.stringValue }.first
    let path = input ?? locations?.first?.path
    return path.flatMap { $0.isEmpty ? nil : $0 }
  }

  private var readFileText: String? {
    let blocks = (content ?? []).compactMap { block -> String? in
      if case let .content(.text(text, _)) = block { return text }
      return nil
    }
    if !blocks.isEmpty { return blocks.joined(separator: "\n") }
    switch rawOutput {
    case let .string(text)?:
      return text
    case let .array(parts)?:
      let texts = parts.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
      return texts.isEmpty ? nil : texts.joined(separator: "\n")
    case let .object(output)?:
      return output["output"]?.stringValue
    default:
      return nil
    }
  }

  private static let mediaExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico",
    "mp4", "mov", "m4v", "webm", "pdf",
  ]

  static func isMedia(path: String) -> Bool {
    mediaExtensions.contains((path as NSString).pathExtension.lowercased())
  }

  static func fileText(_ output: String) -> String {
    var text = output.replacingOccurrences(
      of: #"\n*<system-reminder>[\s\S]*?</system-reminder>\s*"#, with: "", options: .regularExpression)
    if let body = text.range(of: #"<content>\n"#, options: .regularExpression),
      let end = text.range(of: "</content>", options: .backwards),
      body.upperBound <= end.lowerBound
    {
      text = String(text[body.upperBound..<end.lowerBound])
      text = text.replacingOccurrences(
        of: #"\n*\((?:End of file|Showing lines|Output capped)[^\n]*\)\s*$"#, with: "", options: .regularExpression)
    }
    let lines = text.components(separatedBy: "\n")
    for pattern in [#"^\s*\d+\t"#, #"^\s*\d+→"#, #"^\d+: "#] {
      let numbered = lines.filter { !$0.isEmpty }
      guard !numbered.isEmpty,
        numbered.allSatisfy({ $0.range(of: pattern, options: .regularExpression) != nil })
      else { continue }
      let stripped = lines.map { $0.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
      return Self.trimmingTrailingBlankLine(stripped.joined(separator: "\n"))
    }
    return Self.trimmingTrailingBlankLine(text)
  }

  private static func trimmingTrailingBlankLine(_ text: String) -> String {
    text.hasSuffix("\n") ? String(text.dropLast()) : text
  }
}
