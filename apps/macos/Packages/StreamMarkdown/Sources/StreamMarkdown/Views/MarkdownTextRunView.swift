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

    var body: some View {
        Text.withInlineCodeChips(Self.attributedString(for: blocks, theme: theme))
            .font(theme.bodyFont)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .textRenderer(InlineCodeChipRenderer(background: theme.inlineCodeBackground))
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
                // font, approximating the theme's block spacing.
                separator.font = .system(size: max(2, theme.blockSpacing * 0.8))
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
                result += AttributedString("\n")
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
