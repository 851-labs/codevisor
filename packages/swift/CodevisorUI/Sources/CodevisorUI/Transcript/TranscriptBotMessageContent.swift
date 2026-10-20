import Foundation
import TranscriptKit

public struct TranscriptBotMessageContent {
  public let text: String
  public let files: [PreviewFile]

  public init(_ message: TranscriptBotMessage) {
    let segments = assistantMarkdownSegments(message.text, attachments: message.attachments)
    text = Self.markdown(in: segments).trimmingCharacters(in: .whitespacesAndNewlines)
    files = Self.unique(Self.files(in: segments))
  }

  private static func markdown(in segments: [AssistantMarkdownSegment]) -> String {
    segments.map { segment in
      guard case let .markdown(text) = segment else { return "" }
      return text
    }.joined()
  }

  private static func files(in segments: [AssistantMarkdownSegment]) -> [PreviewFile] {
    segments.compactMap { segment in
      guard case let .file(file, _) = segment else { return nil }
      return file
    }
  }

  private static func unique(_ files: [PreviewFile]) -> [PreviewFile] {
    var seen = Set<String>()
    return files.filter { seen.insert($0.id).inserted }
  }
}
