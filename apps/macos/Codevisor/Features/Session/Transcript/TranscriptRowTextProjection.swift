import CodevisorUI
import StreamMarkdown
import TranscriptKit

enum TranscriptRowTextProjection {
  static func surfaceTexts(for row: TranscriptVirtualRow, theme: MarkdownTheme) -> [TranscriptQuotedPrompt] {
    switch row.content {
    case let .markdownChunk(chunk):
      return SettledMarkdownView.plainTextSurfaces(fragment: chunk.content, theme: theme)
        .map { TranscriptQuotedPrompt(text: $0) }
    case let .message(item, waitingOnBackgroundTask: _):
      guard let message = item.userPrompt, !message.text.isEmpty else { return [] }
      return [message.quotedPrompt]
    case let .optimistic(message):
      return message.text.isEmpty ? [] : [message.quotedPrompt]
    case let .botMessage(message, _, _):
      return message.text.isEmpty ? [] : [TranscriptQuotedPrompt(text: message.text)]
    case let .active(item):
      guard let message = item.userPrompt, !message.text.isEmpty else { return [] }
      return [message.quotedPrompt]
    default:
      return []
    }
  }
}
