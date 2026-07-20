import CodevisorCore
import CodevisorTheming
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

/// Which surface a themed toolbar band belongs to.
enum ThemedToolbarRole {
    /// The sidebar column: the band renders the same glass as the sidebar
    /// body (material + theme tint), so rows scrolled beneath it blur
    /// exactly like a native translucent toolbar. Opaque under Reduce
    /// Transparency.
    case sidebar
    /// A content column: the band stays the opaque window (editor)
    /// surface — content surfaces are never glass.
    case content
}

extension View {
    func themedRoot() -> some View {
        modifier(ThemedRoot())
    }

    /// Paints this view's slice of the title bar with a theme surface when a
    /// theme is active. `.toolbarBackground(_:for: .windowToolbar)` can't do
    /// this — it always tints the toolbar across the WHOLE window — so the
    /// toolbar's own backing is hidden and a band the height of the top safe
    /// area is drawn above this view's content instead. The band sits over
    /// scrolled content while the toolbar controls render above it. System
    /// themes keep the native toolbar.
    func themedToolbarBackground(_ theme: Theme, role: ThemedToolbarRole) -> some View {
        modifier(ThemedToolbarBackgroundModifier(role: role))
    }
}

struct ThemedToolbarBackgroundModifier: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let role: ThemedToolbarRole

    func body(content: Content) -> some View {
        if theme.isSystem {
            content
        } else {
            content
                .toolbarBackground(.hidden, for: .windowToolbar)
                .overlay {
                    // Laid out INSIDE the top safe area (ignoresSafeArea,
                    // pinned to the true window top) — never `.offset` out of
                    // bounds. WindowDragGesture registers its drag region at
                    // the LAYOUT position, so an offset band leaves an
                    // invisible window-drag strip over the content below the
                    // toolbar (it swallowed the center pane bar's tab clicks).
                    GeometryReader { proxy in
                        VStack(spacing: 0) {
                            bandFill
                                .frame(height: proxy.safeAreaInsets.top)
                                // Hiding the system toolbar background removes
                                // its implicit drag region on older SDK
                                // compatibility paths. Restore that behavior
                                // with SwiftUI's dedicated native window
                                // gesture.
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

    @ViewBuilder
    private var bandFill: some View {
        switch role {
        case .sidebar where !reduceTransparency:
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill((theme.sidebarTint ?? .clear).opacity(theme.chromeTintAlpha))
            }
        case .sidebar:
            Rectangle().fill(theme.sidebarTint ?? .clear)
        case .content:
            Rectangle().fill(theme.windowBackground)
        }
    }
}
