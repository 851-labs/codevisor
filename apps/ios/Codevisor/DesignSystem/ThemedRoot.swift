import CodevisorUI
import StreamMarkdown
import SwiftUI

struct ThemedRoot: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    let highlight = CodeHighlightTheme.bundled(isDark: colorScheme == .dark)
    content
      .environment(\.codeHighlightTheme, highlight)
      .markdownTheme(makeMarkdownTheme(highlight: highlight.map { ($0.key, $0.json) }))
  }
}
