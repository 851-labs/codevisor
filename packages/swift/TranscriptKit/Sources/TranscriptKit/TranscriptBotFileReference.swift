import Foundation
import MarkdownCore

enum TranscriptBotFileReference {
  static func file(in block: MarkdownBlock) -> PreviewFile? {
    guard case let .paragraph(text) = block, let destination = onlyLink(in: text) else { return nil }
    if let attachment = markdownAttachmentFile(destination) { return attachment }
    guard isWholeLocalFile(destination) else { return nil }
    return PreviewFile(serverPath: destination)
  }

  private static func onlyLink(in text: MarkdownText) -> String? {
    let content = text.spans.filter { !TranscriptBotPartStyle.isBlank($0) }
    guard content.count == 1, case let .link(_, destination, _) = content[0] else { return nil }
    return destination
  }

  private static func isWholeLocalFile(_ destination: String) -> Bool {
    let isAbsolute = destination.hasPrefix("/") || destination.hasPrefix("file://")
    let pointsAtLine = destination.range(of: #"(#L\d+|:\d+)(-L?\d+)?(:\d+)?$"#, options: .regularExpression) != nil
    return isAbsolute && !pointsAtLine
  }
}
