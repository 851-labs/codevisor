import CodevisorUI
import StreamMarkdown
import TranscriptKit

enum TranscriptRowTextProjection {
  static func surfaceTexts(for row: TranscriptVirtualRow, theme: MarkdownTheme) -> [String] {
    switch row.content {
    case let .markdownChunk(chunk):
      return SettledMarkdownView.plainTextSurfaces(blocks: chunk.blocks, theme: theme)
    case let .message(item, waitingOnBackgroundTask: _):
      guard case let .user(message) = item, !message.text.isEmpty else { return [] }
      return [message.text]
    case let .optimistic(message):
      return message.text.isEmpty ? [] : [message.text]
    case let .active(item):
      guard case let .user(message) = item, !message.text.isEmpty else { return [] }
      return [message.text]
    default:
      return []
    }
  }
}
