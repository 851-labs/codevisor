import Foundation

/// Renders inline markdown spans (emphasis, code, links) to `AttributedString`.
///
/// Uses Foundation's inline-only markdown interpretation so block syntax is
/// ignored and partially-formed inline syntax falls back to plain text.
public enum InlineMarkdown {
    public static func attributedString(from markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attributed = try? AttributedString(markdown: markdown, options: options) {
            return attributed
        }
        return AttributedString(markdown)
    }
}
