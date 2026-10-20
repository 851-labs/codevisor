import SwiftUI
import TranscriptKit

struct TranscriptDiffFileSection: View {
  @Environment(\.codeHighlightTheme) private var highlightTheme
  @State private var highlights: [Int: AttributedString] = [:]
  @State private var scrollSync = DiffScrollSync()
  let file: UnifiedDiff.File

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      TranscriptDiffFileHeader(file: file)
      ForEach(file.hunks) { hunk in
        TranscriptDiffHunkHeader(text: hunk.header)
        TranscriptDiffHunkRows(
          rows: hunk.rows,
          highlights: highlights,
          revision: "\(file.id)|\(hunk.id)|\(highlights.isEmpty ? "plain" : "colored")",
          lineNumberDigits: lineNumberDigits,
          scrollSync: scrollSync
        )
      }
    }
    .task(id: highlightTheme?.key) {
      let source = UnifiedDiffHighlightSource(file: file)
      let result = await DiffHighlighting.highlights(
        rows: file.rows, old: source.old, new: source.new, path: file.path, theme: highlightTheme)
      guard !Task.isCancelled else { return }
      highlights = result
    }
  }

  private var lineNumberDigits: Int {
    max(2, String(file.maxLineNumber).count)
  }
}
