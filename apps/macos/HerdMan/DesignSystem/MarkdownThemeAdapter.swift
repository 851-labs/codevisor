import CodeHighlighter
import HerdManCore
import HerdManTheming
import StreamMarkdown
import SwiftUI

/// Bridges the app theme into StreamMarkdown: on-palette code/quote/table
/// colors plus the Shiki highlighter closure. System themes keep the stock
/// markdown look but still get highlighting via GitHub Light/Dark, so code
/// blocks always have the IDE feel.
extension ThemeManager {
    /// The theme document driving code-block highlighting for a scheme: the
    /// selected theme itself (its full JSON, tokenColors included), or the
    /// bundled GitHub themes for the system entries.
    func highlightTheme(for scheme: ThemeDescriptor.SchemeType) -> (key: String, json: String)? {
        let id = themeId(for: scheme)
        let effectiveId =
            ThemeCatalog.isSystemTheme(id: id)
            ? (scheme == .dark ? "shiki:github-dark" : "shiki:github-light")
            : id
        guard
            let data = try? catalog.loadThemeData(id: effectiveId),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        return (effectiveId, json)
    }
}

/// Builds the MarkdownTheme for the active app theme.
func makeMarkdownTheme(theme: Theme, highlight: (key: String, json: String)?) -> MarkdownTheme {
    var markdown = MarkdownTheme.default
    if let palette = theme.palette {
        markdown.codeBackground = Color(rgba: palette.cardBackground)
        // cardHoverBackground (12% fg mix) — cardBackground's 6% mix vanishes
        // against the window background in most custom themes.
        markdown.inlineCodeBackground = Color(rgba: palette.cardHoverBackground)
        markdown.quoteBarColor = theme.border
        markdown.tableBorderColor = theme.separator
    }
    if let highlight {
        markdown.codeThemeKey = highlight.key
        markdown.codeHighlighter = { code, language in
            guard
                let tokens = await CodeHighlighter.shared.highlight(
                    code: code,
                    language: language,
                    themeKey: highlight.key,
                    themeJSON: highlight.json
                )
            else { return nil }
            return attributedCode(tokens)
        }
    }
    return markdown
}

/// Joins highlighted token lines into one attributed string with per-token
/// foreground colors; uncolored tokens inherit the block's text color.
private func attributedCode(_ lines: [[CodeHighlighter.Token]]) -> AttributedString {
    var result = AttributedString()
    for (index, line) in lines.enumerated() {
        if index > 0 { result += AttributedString("\n") }
        result += attributedLine(line)
    }
    return result
}

/// One highlighted token line as an attributed string; uncolored tokens
/// inherit the surrounding text color. Shared with the diff viewer, which
/// styles rows line-by-line.
func attributedLine(_ line: [CodeHighlighter.Token]) -> AttributedString {
    var result = AttributedString()
    for token in line {
        var piece = AttributedString(token.content)
        if let color = token.color, let rgba = RGBA(css: color) {
            piece.foregroundColor = Color(rgba: rgba)
        }
        result += piece
    }
    return result
}
