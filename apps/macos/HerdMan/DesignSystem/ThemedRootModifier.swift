import HerdManCore
import HerdManTheming
import StreamMarkdown
import SwiftUI

private struct TerminalThemeUpdate: Equatable {
    let palette: TerminalPalette?
    let isDark: Bool
}

/// Resolves the active theme from the ThemeManager and injects the token set
/// into the environment. Must be applied at EVERY hosting root — the main
/// `WindowGroup` and the `Settings` scene are separate SwiftUI hierarchies and
/// each needs its own application. Sheets and popovers presented from within a
/// hierarchy inherit the environment automatically.
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
            // Setting the root foreground style makes the hierarchical styles
            // (.primary/.secondary/.tertiary/.quaternary) derive from the
            // theme foreground everywhere, so text hierarchy is on-theme
            // without per-view changes. System themes keep the native styles.
            .foregroundStyle(theme.isSystem ? AnyShapeStyle(.foreground) : AnyShapeStyle(theme.textPrimary))
            // Themed windows paint the theme's content surface behind
            // everything; system themes keep the default window background.
            .background(theme.isSystem ? nil : theme.windowBackground.ignoresSafeArea())
            .tint(theme.isSystem ? nil : theme.accent)
            // Seed the terminal theme before the Ghostty runtime prewarns
            // (initial: true) and re-theme live surfaces on switches.
            .onChange(of: terminalUpdate, initial: true) { _, update in
                HerdManGhosttyApp.applyTheme(update.palette, systemIsDark: update.isDark)
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

    /// Paints this view's slice of the title bar with an opaque theme surface
    /// when a theme is active. `.toolbarBackground(_:for: .windowToolbar)`
    /// can't do this — it always tints the toolbar across the WHOLE window —
    /// so the toolbar's own backing is hidden and an opaque band the height
    /// of the top safe area is drawn above this view's content instead. The
    /// band sits over scrolled content (no bleed-through) while the toolbar
    /// controls render above it. System themes keep the native toolbar.
    @ViewBuilder
    func themedToolbarBackground<S: ShapeStyle>(_ theme: Theme, surface: S) -> some View {
        if theme.isSystem {
            self
        } else {
            self
                .toolbarBackground(.hidden, for: .windowToolbar)
                .overlay {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(surface)
                            .frame(height: proxy.safeAreaInsets.top)
                            .offset(y: -proxy.safeAreaInsets.top)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        }
    }
}
