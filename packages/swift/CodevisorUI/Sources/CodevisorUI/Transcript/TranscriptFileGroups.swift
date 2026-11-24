import Foundation
import TranscriptKit

public enum TranscriptFileGroups {
  public static func siblings(of file: PreviewFile, in conversation: [ConversationItem]) -> [PreviewFile] {
    for item in conversation {
      let files = files(in: item)
      if files.contains(where: { $0.source == file.source }) { return unique(files) }
    }
    return [file]
  }

  private static func files(in item: ConversationItem) -> [PreviewFile] {
    switch item {
    case let .user(message): message.attachments.map(PreviewFile.init(attachment:))
    case let .assistant(message): files(in: message.turn)
    }
  }

  private static func files(in turn: AssistantTurn) -> [PreviewFile] {
    guard case let .text(_, markdown) = turn.finalText else {
      return turn.attachments.map(PreviewFile.init(attachment:))
    }
    return assistantMarkdownSegments(markdown, attachments: turn.attachments).flatMap(files(in:))
  }

  private static func files(in segment: AssistantMarkdownSegment) -> [PreviewFile] {
    switch segment {
    case let .file(file, _): [file]
    case let .markdown(text): images(in: text)
    }
  }

  private static func images(in markdown: String) -> [PreviewFile] {
    guard markdown.contains("![") else { return [] }
    let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
    return imageExpression.matches(in: markdown, range: range).compactMap { match in
      Range(match.range(at: 1), in: markdown).flatMap { markdownImagePreviewFile(String(markdown[$0])) }
    }
  }

  private static func unique(_ files: [PreviewFile]) -> [PreviewFile] {
    var seen = Set<PreviewFile.Source>()
    return files.filter { seen.insert($0.source).inserted }
  }

  private static let imageExpression = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\(\s*<?([^\s)>]+)"#)
}
