import CodevisorCore
import CodevisorTheming
import CodevisorUI
import StreamMarkdown
import SwiftUI

/// The iOS twin of the macOS ThemedRoot: resolves the active theme and
/// injects the token set, the code-highlight theme, and the markdown theme —
/// inline code chips, highlighted code blocks, on-palette markdown colors.
/// Without this the transcript rendered with StreamMarkdown's bare defaults.
struct ThemedRoot: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.colorScheme) private var systemScheme

  func body(content: Content) -> some View {
    let scheme = resolvedScheme
    let theme = Theme(palette: environment.theme.palette(for: scheme))
    let highlight = environment.theme.highlightTheme(for: scheme)
    content
      .environment(\.theme, theme)
      .environment(
        \.codeHighlightTheme,
        highlight.map { CodeHighlightTheme(key: $0.key, json: $0.json) }
      )
      .markdownTheme(markdownTheme(theme: theme, highlight: highlight))
      .foregroundStyle(theme.isSystem ? AnyShapeStyle(.foreground) : AnyShapeStyle(theme.textPrimary))
      .tint(theme.isSystem ? nil : theme.accent)
  }

  /// The shared theme bridge, with spacing opened up for the phone: 17pt
  /// body text needs more line and block air than the Mac's 13pt.
  private func markdownTheme(
    theme: Theme,
    highlight: (key: String, json: String)?
  ) -> MarkdownTheme {
    var markdown = makeMarkdownTheme(theme: theme, highlight: highlight)
    markdown.lineSpacing = 5
    markdown.blockSpacing = 12
    markdown.listItemSpacing = 6
    return markdown
  }

  private var resolvedScheme: ThemeDescriptor.SchemeType {
    switch environment.theme.mode {
    case .light: return .light
    case .dark: return .dark
    case .system: return systemScheme == .dark ? .dark : .light
    }
  }
}
