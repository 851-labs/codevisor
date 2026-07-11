import SwiftUI

/// Renders a run of consecutive text-like markdown blocks (headings,
/// paragraphs, lists) as a SINGLE `Text` built from one merged
/// `AttributedString`.
///
/// This is deliberate: `.textSelection(.enabled)` is scoped per `Text` view on
/// macOS, so selection can never span two separate `Text`s. Rendering each
/// block as its own `Text` (the old approach) made multi-line selection across
/// paragraphs impossible. One merged `Text` gives continuous, native
/// multi-block selection.
struct MarkdownTextRunView: View {
    let blocks: [MarkdownBlock]
    @Environment(\.markdownTheme) private var theme
    /// Memoizes the built `Text`: `body` runs far more often than `blocks`
    /// changes (sibling streaming churn, hover state, the finalize collapse),
    /// and rebuilding the merged AttributedString plus the chip-run walk is
    /// O(run length) — for a finalized message, the whole document.
    @State private var memo = TextRunMemo()

    var body: some View {
        let rendered = memo.rendered(for: blocks, theme: theme)
        let text = rendered.text
            .font(theme.bodyFont)
            .lineSpacing(theme.lineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        // Chip-bearing runs get a glyph-less backdrop `Text` that paints the
        // rounded chip backgrounds: the selectable foreground text ignores
        // custom TextRenderers (see InlineCodeChipRenderer), and only runs
        // that actually contain inline code pay for the second layout — the
        // common no-code paragraph stays a single stock `Text`.
        if rendered.hasChips {
            text.background(alignment: .topLeading) {
                rendered.text
                    .font(theme.bodyFont)
                    .lineSpacing(theme.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .textRenderer(
                        InlineCodeChipRenderer(
                            background: theme.inlineCodeBackground,
                            cornerRadius: theme.inlineCodeCornerRadius
                        )
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            text
        }
    }

    /// Builds the single selectable `Text` for the run. When the merged
    /// attributed string contains inline-code chips, the `Text` is built by
    /// concatenating chip / non-chip pieces so chip pieces can carry the
    /// `InlineCodeChip` custom attribute (concatenation preserves the single
    /// `Text`, and with it cross-block selection). `hasChips` tells the view
    /// whether the chip renderer needs to be attached at all.
    static func text(for blocks: [MarkdownBlock], theme: MarkdownTheme) -> (text: Text, hasChips: Bool) {
        let merged = attributedString(for: blocks, theme: theme)
        guard merged.runs.contains(where: { $0[InlineCodeChipAttribute.self] == true }) else {
            return (Text(merged), false)
        }
        var text = Text(verbatim: "")
        for piece in InlineMarkdown.chipPieces(in: merged) {
            let pieceText = Text(piece.text)
            if piece.isChip {
                text = Text("\(text)\(pieceText.customAttribute(InlineCodeChip()))")
            } else {
                text = Text("\(text)\(pieceText)")
            }
        }
        return (text, true)
    }

    /// Merges the blocks into one attributed string. Blocks are separated by a
    /// blank line whose font size approximates `theme.blockSpacing`, so the
    /// visual rhythm matches the VStack spacing used between non-text segments.
    static func attributedString(for blocks: [MarkdownBlock], theme: MarkdownTheme) -> AttributedString {
        var result = AttributedString()
        for (index, block) in blocks.enumerated() {
            let piece = attributedString(for: block, theme: theme)
            guard !piece.characters.isEmpty else { continue }
            if index > 0, !result.characters.isEmpty {
                var separator = AttributedString("\n\n")
                // The empty line between blocks takes its height from this
                // font, approximating the theme's block spacing. Line spacing
                // is applied above and below the blank line too, so subtract
                // it to keep the block rhythm as lineSpacing grows.
                separator.font = .system(size: max(2, (theme.blockSpacing - 2 * theme.lineSpacing) * 0.8))
                result += separator
            }
            result += piece
        }
        return result
    }

    private static func attributedString(for block: MarkdownBlock, theme: MarkdownTheme) -> AttributedString {
        switch block {
        case let .heading(level, text):
            var attributed = InlineMarkdown.attributedString(from: text)
            attributed.font = headingFont(for: level).weight(.semibold)
            // Code chip styling comes after the heading font so `code` spans
            // keep their monospaced chip look inside headings.
            return InlineMarkdown.styleInlineCode(in: attributed, theme: theme)

        case let .paragraph(text):
            // No explicit font: inherits the body font from the Text view, so
            // strong/emphasis presentation intents resolve correctly.
            return InlineMarkdown.attributedString(from: text, theme: theme)

        case let .bulletList(items):
            return list(items: items.map { (marker: "•", text: $0) }, theme: theme)

        case let .orderedList(items):
            return list(items: items.map { (marker: "\($0.number).", text: $0.text) }, theme: theme)

        case .codeBlock, .blockQuote, .table, .thematicBreak:
            // Not text-run blocks; rendered by MarkdownBlockView instead.
            return AttributedString()
        }
    }

    private static func list(items: [(marker: String, text: String)], theme: MarkdownTheme) -> AttributedString {
        var result = AttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 {
                // Same trick as the block separator: an empty line whose tiny
                // font height adds `listItemSpacing` of air between items,
                // since per-range line spacing isn't available in SwiftUI.
                // Line spacing already contributes around the blank line, so
                // it counts toward the item gap.
                var separator = AttributedString("\n\n")
                separator.font = .system(size: max(1, (theme.listItemSpacing - 2 * theme.lineSpacing) * 0.8))
                result += separator
            }
            var marker = AttributedString("\(item.marker) ")
            marker.foregroundColor = .secondary
            result += marker
            result += InlineMarkdown.attributedString(from: item.text, theme: theme)
        }
        return result
    }

    static func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        case 4: return .headline
        default: return .subheadline
        }
    }
}

/// Last-value memo for a text run's built `Text`. A plain class held in
/// `@State` — non-observable, so cache writes never re-render the view.
/// The unchanged-blocks comparison is O(1) in the streaming steady state:
/// the segmenter pointer-stabilizes unchanged segments, so `==` on the same
/// String storage short-circuits. Returning the identical `Text` value also
/// lets SwiftUI's change detection skip the row entirely.
@MainActor
private final class TextRunMemo {
    private var blocks: [MarkdownBlock]?
    private var themeFingerprint: Int?
    private var cached: (text: Text, hasChips: Bool)?

    func rendered(for blocks: [MarkdownBlock], theme: MarkdownTheme) -> (text: Text, hasChips: Bool) {
        let fingerprint = theme.renderFingerprint
        if let cached, blocks == self.blocks, fingerprint == themeFingerprint {
            return cached
        }
        let rendered = MarkdownTextRunView.text(for: blocks, theme: theme)
        self.blocks = blocks
        themeFingerprint = fingerprint
        cached = rendered
        return rendered
    }
}
