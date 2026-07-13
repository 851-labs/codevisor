import Foundation
import SwiftUI
import os

/// Package-private logging handle: StreamMarkdown must not depend on
/// CodevisorCore, so it carries its own `Logger` under the app's shared
/// subsystem. `.debug` only — this file is on the per-render hot path.
private let log = Logger(subsystem: "com.851labs.codevisor", category: "markdown")

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
    /// slightly smaller monospaced font, padded on each side with a narrow
    /// no-break space, and tagged with `InlineCodeChipAttribute` so the chip
    /// renderer can paint a rounded background behind the run (see
    /// `InlineCodeChipRenderer`).
    public static func attributedString(from markdown: String, theme: MarkdownTheme) -> AttributedString {
        styleInlineCode(in: attributedString(from: markdown), theme: theme)
    }

    /// Applies the inline-code chip styling to any `.code` runs in an
    /// already-parsed attributed string. The chip background itself is NOT an
    /// attribute (`AttributedString.backgroundColor` can only paint square
    /// rects): runs are tagged with `InlineCodeChipAttribute` and painted by
    /// `InlineCodeChipRenderer` with rounded corners.
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
            piece[InlineCodeChipAttribute.self] = true
            // Narrow no-break spaces extend the chip background slightly past
            // the glyphs without allowing a line break between pad and code.
            var pad = AttributedString("\u{202F}")
            pad.font = theme.inlineCodeFont
            pad[InlineCodeChipAttribute.self] = true
            result += pad + piece + pad
        }
        return result
    }

    /// Splits an attributed string into maximal contiguous pieces of chip /
    /// non-chip content. `MarkdownTextRunView` builds its merged `Text` by
    /// concatenating these pieces, attaching the SwiftUI `InlineCodeChip`
    /// custom attribute to the chip ones — `Text(AttributedString)` cannot
    /// carry custom text attributes directly, but `Text` concatenation
    /// preserves them and keeps selection continuous.
    static func chipPieces(in attributed: AttributedString) -> [(text: AttributedString, isChip: Bool)] {
        var pieces: [(text: AttributedString, isChip: Bool)] = []
        for run in attributed.runs {
            let isChip = run[InlineCodeChipAttribute.self] == true
            let piece = AttributedString(attributed[run.range])
            if !pieces.isEmpty, pieces[pieces.count - 1].isChip == isChip {
                pieces[pieces.count - 1].text += piece
            } else {
                pieces.append((piece, isChip))
            }
        }
        return pieces
    }
}
