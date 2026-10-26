import CodeHighlighter
import SwiftUI
import TranscriptKit

struct ReadFileBodyView: View {
  let read: ReadFileOutput

  @Environment(\.transcriptAttachmentThumbnail) private var thumbnail
  @Environment(\.codeHighlightTheme) private var highlightTheme
  @State private var syntax: [[CodeHighlighter.Token]]?

  var body: some View {
    switch read.content {
    case let .media(captured):
      if let captured, let thumbnail {
        thumbnail(captured)
      } else {
        let file = captured ?? PreviewFile(serverPath: read.path)
        Label(file.name, systemImage: file.kind == .image ? "photo" : "doc")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    case let .text(text):
      PlainCodeBodyView(output: text, syntax: syntax)
        .task(id: HighlightRequest(path: read.path, text: text, theme: highlightTheme?.key)) {
          syntax = await highlighted(text)
        }
    }
  }

  private struct HighlightRequest: Equatable {
    let path: String
    let text: String
    let theme: String?
  }

  private func highlighted(_ text: String) async -> [[CodeHighlighter.Token]]? {
    guard let theme = highlightTheme, let language = CodeHighlighter.language(forPath: read.path) else {
      return nil
    }
    return await CodeHighlighter.shared.highlight(
      code: text, language: language, themeKey: theme.key, themeJSON: theme.json)
  }
}
