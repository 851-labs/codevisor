import CodevisorUI
import StreamMarkdown
import TranscriptKit

/// Plain text for rows the virtualizer has unmounted, in the same surface
/// order a mounted row presents, so a transcript-wide selection can be
/// copied without mounting every row it spans.
///
/// Prose, code, tables, and user prompts are covered — the bulk of any
/// transcript. Rows whose text only exists inside SwiftUI content (tool call
/// output, diffs) contribute while mounted and are skipped once unmounted.
enum TranscriptRowTextProjection {
  static func surfaceTexts(for row: TranscriptVirtualRow, theme: MarkdownTheme) -> [String] {
    switch row.content {
    case let .markdownChunk(chunk):
      return SettledMarkdownView.plainTextSurfaces(blocks: chunk.blocks, theme: theme)
    case let .message(item, waitingOnBackgroundTask: _):
      guard case let .user(message) = item, !message.text.isEmpty else { return [] }
      return [message.text]
    case let .optimistic(message, showsStartingAgent: _):
      return message.text.isEmpty ? [] : [message.text]
    case let .active(item):
      guard case let .user(message) = item, !message.text.isEmpty else { return [] }
      return [message.text]
    default:
      return []
    }
  }
}
