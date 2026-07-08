import SwiftUI

/// Asynchronously turns a fenced code block into a syntax-highlighted
/// attributed string, or nil to keep plain text (unknown language,
/// highlighter unavailable). Injected by the host app; the package itself
/// ships no highlighter.
public typealias CodeHighlighting = @Sendable (_ code: String, _ language: String?) async ->
    AttributedString?

/// Visual styling for markdown rendering, injected through the environment so
/// the host app can customize fonts, spacing, and colors.
public struct MarkdownTheme: Sendable {
    public var bodyFont: Font
    public var codeFont: Font
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
        inlineCodeFont: Font = .system(.callout, design: .monospaced),
        blockSpacing: CGFloat = 10,
        listItemSpacing: CGFloat = 4,
        lineSpacing: CGFloat = 3,
        codeBackground: Color = Color.secondary.opacity(0.12),
        inlineCodeBackground: Color = Color.secondary.opacity(0.18),
        quoteBarColor: Color = Color.secondary.opacity(0.4),
        tableBorderColor: Color = Color.secondary.opacity(0.25),
        codeHighlighter: CodeHighlighting? = nil,
        codeThemeKey: String = "default"
    ) {
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.inlineCodeFont = inlineCodeFont
        self.blockSpacing = blockSpacing
        self.listItemSpacing = listItemSpacing
        self.lineSpacing = lineSpacing
        self.codeBackground = codeBackground
        self.inlineCodeBackground = inlineCodeBackground
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
        hasher.combine(inlineCodeFont)
        hasher.combine(blockSpacing)
        hasher.combine(listItemSpacing)
        hasher.combine(codeBackground)
        hasher.combine(inlineCodeBackground)
        hasher.combine(quoteBarColor)
        hasher.combine(tableBorderColor)
        hasher.combine(codeThemeKey)
        return hasher.finalize()
    }
}

private struct MarkdownThemeKey: EnvironmentKey {
    static let defaultValue = MarkdownTheme.default
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
}
