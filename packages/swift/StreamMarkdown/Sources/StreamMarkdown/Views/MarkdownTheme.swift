import Foundation
import SwiftUI

/// Asynchronously turns a fenced code block into a syntax-highlighted
/// attributed string, or nil to keep plain text (unknown language,
/// highlighter unavailable). Injected by the host app; the package itself
/// ships no highlighter.
public typealias CodeHighlighting =
    @Sendable (_ code: String, _ language: String?) async ->
    AttributedString?

/// Lets a host intercept links rendered by StreamMarkdown's native TextKit
/// views. Returning `true` means the host handled the URL; returning `false`
/// preserves the platform's normal URL-opening behavior.
public struct MarkdownLinkAction: @unchecked Sendable {
    private let handler: @MainActor (URL) -> Bool

    public init(_ handler: @escaping @MainActor (URL) -> Bool) {
        self.handler = handler
    }

    @MainActor
    public func callAsFunction(_ url: URL) -> Bool {
        handler(url)
    }
}

/// Visual styling for markdown rendering, injected through the environment so
/// the host app can customize fonts, spacing, and colors.
public struct MarkdownTheme: Sendable {
    public var bodyFont: Font
    public var codeFont: Font
    /// Primary and secondary prose colors. Native TextKit views cannot inherit
    /// SwiftUI's foreground-style environment, so the host supplies both
    /// semantic colors explicitly with the rest of the markdown theme.
    public var textForeground: Color
    public var secondaryTextForeground: Color
    /// Base foreground for fenced code. Highlighted tokens override this;
    /// uncolored tokens inherit it.
    public var codeForeground: Color
    /// Font for `` `inline code` `` chips: monospaced and a touch smaller
    /// than the body text so chips sit flush in a line of prose.
    public var inlineCodeFont: Font
    public var blockSpacing: CGFloat
    /// Extra vertical breathing room between list items (points).
    public var listItemSpacing: CGFloat
    /// Extra space between wrapped lines within a block (points).
    public var lineSpacing: CGFloat
    public var codeBackground: Color
    /// Background tint for `` `inline code` `` chips.
    public var inlineCodeBackground: Color
    /// Corner radius of the rounded chip background painted behind
    /// `` `inline code` `` runs (clamped to half the chip height at draw
    /// time).
    public var inlineCodeCornerRadius: CGFloat
    public var quoteBarColor: Color
    public var tableBorderColor: Color
    public var codeHighlighter: CodeHighlighting?
    /// A stable identity for the active highlight theme (e.g. its id).
    /// Closures can't be compared, so code blocks watch this to know when a
    /// theme switch requires re-highlighting.
    public var codeThemeKey: String

    public init(
        bodyFont: Font = .body,
        codeFont: Font = .system(.callout, design: .monospaced),
        textForeground: Color = .primary,
        secondaryTextForeground: Color = .secondary,
        codeForeground: Color = .primary,
        inlineCodeFont: Font = .system(.callout, design: .monospaced),
        blockSpacing: CGFloat = 10,
        listItemSpacing: CGFloat = 4,
        lineSpacing: CGFloat = 3,
        codeBackground: Color = Color.secondary.opacity(0.12),
        inlineCodeBackground: Color = Color.secondary.opacity(0.18),
        inlineCodeCornerRadius: CGFloat = 4,
        quoteBarColor: Color = Color.secondary.opacity(0.4),
        tableBorderColor: Color = Color.secondary.opacity(0.25),
        codeHighlighter: CodeHighlighting? = nil,
        codeThemeKey: String = "default"
    ) {
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.textForeground = textForeground
        self.secondaryTextForeground = secondaryTextForeground
        self.codeForeground = codeForeground
        self.inlineCodeFont = inlineCodeFont
        self.blockSpacing = blockSpacing
        self.listItemSpacing = listItemSpacing
        self.lineSpacing = lineSpacing
        self.codeBackground = codeBackground
        self.inlineCodeBackground = inlineCodeBackground
        self.inlineCodeCornerRadius = inlineCodeCornerRadius
        self.quoteBarColor = quoteBarColor
        self.tableBorderColor = tableBorderColor
        self.codeHighlighter = codeHighlighter
        self.codeThemeKey = codeThemeKey
    }

    public static let `default` = MarkdownTheme()

    /// Hash of every render-affecting field except the highlighter closure
    /// (closures can't be compared; `codeThemeKey` stands in for it, by the
    /// same contract code blocks rely on). Render memos key on this to
    /// detect theme switches without making the whole theme Equatable.
    var renderFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(bodyFont)
        hasher.combine(codeFont)
        hasher.combine(textForeground)
        hasher.combine(secondaryTextForeground)
        hasher.combine(codeForeground)
        hasher.combine(inlineCodeFont)
        hasher.combine(blockSpacing)
        hasher.combine(listItemSpacing)
        hasher.combine(lineSpacing)
        hasher.combine(codeBackground)
        hasher.combine(inlineCodeBackground)
        hasher.combine(inlineCodeCornerRadius)
        hasher.combine(quoteBarColor)
        hasher.combine(tableBorderColor)
        hasher.combine(codeThemeKey)
        return hasher.finalize()
    }
}

private struct MarkdownThemeKey: EnvironmentKey {
    static let defaultValue = MarkdownTheme.default
}

private struct MarkdownTableBleedKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct MarkdownLinkActionKey: EnvironmentKey {
    static let defaultValue: MarkdownLinkAction? = nil
}

public extension EnvironmentValues {
    /// The horizontal padding the host lays around markdown content, which a
    /// too-wide table's horizontal scroller may bleed through (iOS): the
    /// table rests aligned with the text column, but its scroll viewport
    /// extends `markdownTableBleed` points past each side, so scrolling
    /// carries the table all the way to the screen edges instead of stopping
    /// at the text gutter. Zero (the default) keeps tables inside the text
    /// column. Text and every other block keep the host padding untouched.
    var markdownTableBleed: CGFloat {
        get { self[MarkdownTableBleedKey.self] }
        set { self[MarkdownTableBleedKey.self] = newValue }
    }

    var markdownLinkAction: MarkdownLinkAction? {
        get { self[MarkdownLinkActionKey.self] }
        set { self[MarkdownLinkActionKey.self] = newValue }
    }
}

public extension EnvironmentValues {
    var markdownTheme: MarkdownTheme {
        get { self[MarkdownThemeKey.self] }
        set { self[MarkdownThemeKey.self] = newValue }
    }
}

public extension View {
    /// Sets the markdown theme for this view hierarchy.
    func markdownTheme(_ theme: MarkdownTheme) -> some View {
        environment(\.markdownTheme, theme)
    }

    /// Handles Markdown links from both native TextKit surfaces and portable
    /// SwiftUI text (used by iOS tables). Unhandled URLs continue to the
    /// operating system.
    func markdownLinkHandler(
        _ handler: @escaping @MainActor (URL) -> Bool
    ) -> some View {
        let action = MarkdownLinkAction(handler)
        return environment(\.markdownLinkAction, action)
            .environment(
                \.openURL,
                OpenURLAction { url in
                    action(url) ? .handled : .systemAction
                }
            )
    }
}
