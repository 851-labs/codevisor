import CodevisorUI
import StreamMarkdown
import SwiftUI

struct ThemedRoot: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    let isDark = colorScheme == .dark
    let highlight = CodeHighlightTheme.bundled(isDark: isDark)
    content
      .environment(\.codeHighlightTheme, highlight)
      .markdownTheme(makeMarkdownTheme(highlight: highlight.map { ($0.key, $0.json) }))
      .onChange(of: isDark, initial: true) { _, isDark in
        CodevisorGhosttyApp.applySystemAppearance(isDark: isDark)
      }
  }
}

extension View {
  func themedRoot() -> some View {
    modifier(ThemedRoot())
  }
}
