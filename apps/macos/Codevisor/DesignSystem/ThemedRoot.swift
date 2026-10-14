import CodevisorCore
import CodevisorTheming
import StreamMarkdown
import SwiftUI
import CodevisorUI

private struct TerminalThemeUpdate: Equatable {
  let palette: TerminalPalette?
  let isDark: Bool
}

struct ThemedRoot: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.colorScheme) private var systemScheme

  func body(content: Content) -> some View {
    let scheme = resolvedScheme
    let theme = Theme(palette: environment.theme.palette(for: scheme))
    let highlight = environment.theme.highlightTheme(for: scheme)
    let terminalUpdate = TerminalThemeUpdate(
      palette: theme.palette?.terminal,
      isDark: scheme == .dark
    )
    content
      .environment(\.theme, theme)
      .environment(
        \.codeHighlightTheme,
        highlight.map { CodeHighlightTheme(key: $0.key, json: $0.json) }
      )
      .markdownTheme(makeMarkdownTheme(theme: theme, highlight: highlight))
      .foregroundStyle(theme.isSystem ? AnyShapeStyle(.foreground) : AnyShapeStyle(theme.textPrimary))
      .background(theme.isSystem ? nil : theme.windowBackground.ignoresSafeArea())
      .tint(theme.isSystem ? nil : theme.accent)
      .onChange(of: terminalUpdate, initial: true) { _, update in
        CodevisorGhosttyApp.applyTheme(update.palette, systemIsDark: update.isDark)
      }
  }

  private var resolvedScheme: ThemeDescriptor.SchemeType {
    switch environment.theme.mode {
    case .light: return .light
    case .dark: return .dark
    case .system: return systemScheme == .dark ? .dark : .light
    }
  }
}

extension View {
  func themedRoot() -> some View {
    modifier(ThemedRoot())
  }

  func themedToolbarBackground(_ theme: Theme) -> some View {
    modifier(ThemedToolbarBackgroundModifier())
  }
}

struct ThemedToolbarBackgroundModifier: ViewModifier {
  @Environment(\.theme) private var theme

  func body(content: Content) -> some View {
    if theme.isSystem {
      content
    } else {
      content
        .toolbarBackground(.hidden, for: .windowToolbar)
        .overlay {
          GeometryReader { proxy in
            VStack(spacing: 0) {
              Rectangle().fill(theme.windowBackground)
                .frame(height: proxy.safeAreaInsets.top)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents()
              Spacer(minLength: 0)
            }
            .ignoresSafeArea(edges: .top)
          }
          .accessibilityHidden(true)
        }
    }
  }
}
