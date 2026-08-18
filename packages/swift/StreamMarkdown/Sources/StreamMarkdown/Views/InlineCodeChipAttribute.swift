import Foundation

/// Marks the runs of an `AttributedString` (the code span plus its NNBSP
/// pads) that belong to an `` `inline code` `` chip. The Markdown-to-AppKit
/// bridge converts this marker to `.streamMarkdownRoundedBackground`, which
/// the TextKit layout manager paints behind the selectable glyphs.
enum InlineCodeChipAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "com.851labs.codevisor.inlineCodeChip"
}
