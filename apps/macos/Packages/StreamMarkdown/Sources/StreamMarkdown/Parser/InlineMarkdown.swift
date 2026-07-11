import Foundation
import SwiftUI
import os

/// Package-private logging handle: StreamMarkdown must not depend on
/// HerdManCore, so it carries its own `Logger` under the app's shared
/// subsystem. `.debug` only — this file is on the per-render hot path.
private let log = Logger(subsystem: "com.851labs.herdman", category: "markdown")

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
        do {
            return try AttributedString(markdown: markdown, options: options)
        } catch {
            // Expected for partially-formed streaming markdown; plain text is
            // the designed fallback. Debug-only so the hot path stays quiet.
            log.debug(
                "Inline markdown parse failed, falling back to plain text: \(String(describing: error), privacy: .public)"
            )
            return AttributedString(markdown)
        }
    }

    /// Parses inline markdown and styles `` `code` `` spans as chips: a
    /// slightly smaller monospaced font on a tinted background, padded on each
    /// side with a narrow no-break space so the background extends a little
    /// past the glyphs (approximating the pill look within a single
    /// selectable `Text`).
    public static func attributedString(from markdown: String, theme: MarkdownTheme) -> AttributedString {
        styleInlineCode(in: attributedString(from: markdown), theme: theme)
    }

    /// Applies the inline-code chip styling to any `.code` runs in an
    /// already-parsed attributed string.
    public static func styleInlineCode(in attributed: AttributedString, theme: MarkdownTheme) -> AttributedString {
        guard attributed.runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true })
        else { return attributed }

        var result = AttributedString()
        for run in attributed.runs {
            var piece = AttributedString(attributed[run.range])
            guard run.inlinePresentationIntent?.contains(.code) == true else {
                result += piece
                continue
            }
            piece.font = theme.inlineCodeFont
            piece.backgroundColor = theme.inlineCodeBackground
            // Narrow no-break spaces carry the chip background slightly past
            // the glyphs without allowing a line break between pad and code.
            var pad = AttributedString("\u{202F}")
            pad.font = theme.inlineCodeFont
            pad.backgroundColor = theme.inlineCodeBackground
            result += pad + piece + pad
        }
        return result
    }
}
