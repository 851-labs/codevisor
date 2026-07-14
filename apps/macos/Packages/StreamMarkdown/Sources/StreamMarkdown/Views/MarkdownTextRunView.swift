import AppKit
import SwiftUI

/// Renders consecutive text-like Markdown blocks in one native TextKit view.
/// A single text storage keeps selection continuous across headings,
/// paragraphs, and lists without SwiftUI changing layout engines on click.
struct MarkdownTextRunView: View {
    let blocks: [MarkdownBlock]
    let foregroundColor: Color
    @Environment(\.markdownTheme) private var theme
    /// The segmenter pointer-stabilizes settled blocks, so this memo makes
    /// repeated transcript body evaluations O(1) for unchanged text.
    @State private var memo = TextRunMemo()

    var body: some View {
        SelectableTextView(
            attributedText: memo.rendered(
                for: blocks,
                theme: theme,
                foregroundColor: foregroundColor
            )
        )
    }
}

/// Converts parsed Markdown runs to AppKit attributes. Font choices match the
/// semantic SwiftUI styles previously used by `MarkdownTextRunView`; the host
/// does not override MarkdownTheme's fonts today (tables follow the same
/// semantic-font contract).
enum MarkdownTextRunRenderer {
    static func attributedString(
        for blocks: [MarkdownBlock],
        theme: MarkdownTheme,
        foregroundColor: Color
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let foreground = NSColor(foregroundColor)
        let chipBackground = TextKitRoundedBackground(
            color: NSColor(theme.inlineCodeBackground),
            cornerRadius: theme.inlineCodeCornerRadius
        )

        for (index, block) in blocks.enumerated() {
            let piece = attributedString(
                for: block,
                theme: theme,
                foreground: foreground,
                chipBackground: chipBackground
            )
            guard piece.length > 0 else { continue }
            if index > 0, result.length > 0 {
                result.append(
                    verticalSeparator(
                        size: max(2, (theme.blockSpacing - 2 * theme.lineSpacing) * 0.8),
                        lineSpacing: theme.lineSpacing,
                        foreground: foreground
                    )
                )
            }
            result.append(piece)
        }
        return result.copy() as! NSAttributedString
    }

    private static func attributedString(
        for block: MarkdownBlock,
        theme: MarkdownTheme,
        foreground: NSColor,
        chipBackground: TextKitRoundedBackground
    ) -> NSAttributedString {
        switch block {
        case let .heading(level, text):
            inlineAttributed(
                text,
                baseFont: headingFont(for: level),
                theme: theme,
                foreground: foreground,
                chipBackground: chipBackground
            )

        case let .paragraph(text):
            inlineAttributed(
                text,
                baseFont: bodyFont,
                theme: theme,
                foreground: foreground,
                chipBackground: chipBackground
            )

        case let .bulletList(items):
            list(
                items: items.map { (marker: "•", text: $0) },
                theme: theme,
                foreground: foreground,
                chipBackground: chipBackground
            )

        case let .orderedList(items):
            list(
                items: items.map { (marker: "\($0.number).", text: $0.text) },
                theme: theme,
                foreground: foreground,
                chipBackground: chipBackground
            )

        case .codeBlock, .blockQuote, .table, .thematicBreak:
            NSAttributedString()
        }
    }

    private static func list(
        items: [(marker: String, text: String)],
        theme: MarkdownTheme,
        foreground: NSColor,
        chipBackground: TextKitRoundedBackground
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 {
                result.append(
                    verticalSeparator(
                        size: max(1, (theme.listItemSpacing - 2 * theme.lineSpacing) * 0.8),
                        lineSpacing: theme.lineSpacing,
                        foreground: foreground
                    )
                )
            }
            result.append(
                NSAttributedString(
                    string: "\(item.marker) ",
                    attributes: baseAttributes(
                        font: bodyFont,
                        foreground: NSColor(theme.secondaryTextForeground),
                        lineSpacing: theme.lineSpacing
                    )
                )
            )
            result.append(
                inlineAttributed(
                    item.text,
                    baseFont: bodyFont,
                    theme: theme,
                    foreground: foreground,
                    chipBackground: chipBackground
                )
            )
        }
        return result
    }

    private static func inlineAttributed(
        _ markdown: String,
        baseFont: NSFont,
        theme: MarkdownTheme,
        foreground: NSColor,
        chipBackground: TextKitRoundedBackground
    ) -> NSAttributedString {
        let parsed = InlineMarkdown.attributedString(from: markdown, theme: theme)
        let output = NSMutableAttributedString()
        let codeFont = NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
            weight: .regular
        )

        for run in parsed.runs {
            let substring = String(parsed[run.range].characters)
            guard !substring.isEmpty else { continue }
            let intent = run.inlinePresentationIntent
            let isCode = run[InlineCodeChipAttribute.self] == true
                || intent?.contains(.code) == true
            let font = isCode
                ? codeFont
                : styled(
                    baseFont,
                    bold: intent?.contains(.stronglyEmphasized) == true,
                    italic: intent?.contains(.emphasized) == true
                )
            var attributes = baseAttributes(
                font: font,
                foreground: run.link == nil ? foreground : .linkColor,
                lineSpacing: theme.lineSpacing
            )
            if let link = run.link {
                attributes[.link] = link
            }
            if isCode {
                attributes[.streamMarkdownRoundedBackground] = chipBackground
            }
            output.append(NSAttributedString(string: substring, attributes: attributes))
        }
        return output
    }

    private static func verticalSeparator(
        size: CGFloat,
        lineSpacing: CGFloat,
        foreground: NSColor
    ) -> NSAttributedString {
        NSAttributedString(
            string: "\n\n",
            attributes: baseAttributes(
                font: .systemFont(ofSize: size),
                foreground: foreground,
                lineSpacing: lineSpacing
            )
        )
    }

    private static func baseAttributes(
        font: NSFont,
        foreground: NSColor,
        lineSpacing: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        return [
            .font: font,
            .foregroundColor: foreground,
            .paragraphStyle: paragraph,
        ]
    }

    private static var bodyFont: NSFont {
        .preferredFont(forTextStyle: .body)
    }

    static func headingFont(for level: Int) -> NSFont {
        let style: NSFont.TextStyle = switch level {
        case 1: .title1
        case 2: .title2
        case 3: .title3
        case 4: .headline
        default: .subheadline
        }
        return styled(.preferredFont(forTextStyle: style), bold: true, italic: false)
    }

    private static func styled(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        guard bold || italic else { return font }
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}

/// Last-value memo for the immutable attributed string handed to both the
/// displayed TextKit view and its scratch measurer. Returning the same object
/// identity lets both paths skip unchanged settled Markdown in O(1).
@MainActor
private final class TextRunMemo {
    private var blocks: [MarkdownBlock]?
    private var themeFingerprint: Int?
    private var foregroundColor: Color?
    private var cached: NSAttributedString?

    func rendered(
        for blocks: [MarkdownBlock],
        theme: MarkdownTheme,
        foregroundColor: Color
    ) -> NSAttributedString {
        let fingerprint = theme.renderFingerprint
        if let cached,
           blocks == self.blocks,
           fingerprint == themeFingerprint,
           foregroundColor == self.foregroundColor
        {
            return cached
        }
        let rendered = MarkdownTextRunRenderer.attributedString(
            for: blocks,
            theme: theme,
            foregroundColor: foregroundColor
        )
        self.blocks = blocks
        themeFingerprint = fingerprint
        self.foregroundColor = foregroundColor
        cached = rendered
        return rendered
    }
}
