import SwiftUI

/// Visual styling for markdown rendering, injected through the environment so
/// the host app can customize fonts, spacing, and colors.
public struct MarkdownTheme: Sendable {
    public var bodyFont: Font
    public var codeFont: Font
    public var blockSpacing: CGFloat
    public var codeBackground: Color
    public var quoteBarColor: Color
    public var tableBorderColor: Color

    public init(
        bodyFont: Font = .body,
        codeFont: Font = .system(.callout, design: .monospaced),
        blockSpacing: CGFloat = 10,
        codeBackground: Color = Color.secondary.opacity(0.12),
        quoteBarColor: Color = Color.secondary.opacity(0.4),
        tableBorderColor: Color = Color.secondary.opacity(0.25)
    ) {
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.blockSpacing = blockSpacing
        self.codeBackground = codeBackground
        self.quoteBarColor = quoteBarColor
        self.tableBorderColor = tableBorderColor
    }

    public static let `default` = MarkdownTheme()
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
