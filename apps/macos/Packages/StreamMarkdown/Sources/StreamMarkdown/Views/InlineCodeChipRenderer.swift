import SwiftUI

/// Marks the runs of an `AttributedString` (the code span plus its NNBSP
/// pads) that belong to an `` `inline code` `` chip. Carried from
/// `InlineMarkdown.styleInlineCode` to the `Text` builder, which converts it
/// into the SwiftUI custom text attribute the chip renderer keys on. SwiftUI
/// itself ignores unknown `AttributedString` keys, so the attribute is inert
/// anywhere the renderer isn't attached.
enum InlineCodeChipAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "com.851labs.codevisor.inlineCodeChip"
}

/// The `Text`-level marker for chip runs. `Text.Layout.Run`s tagged with this
/// (via `Text.customAttribute`) get a rounded background painted behind them
/// by `InlineCodeChipRenderer`.
struct InlineCodeChip: TextAttribute {}

/// Draws ONLY the rounded-rect chip backgrounds of a text layout — never the
/// glyphs. Attached to the glyph-less backdrop `Text` that
/// `MarkdownTextRunView` layers BEHIND its selectable foreground `Text`.
///
/// Why a backdrop layer: `.textSelection(.enabled)` swaps macOS `Text` onto a
/// selectable backing view that ignores custom `TextRenderer`s entirely
/// (verified in a real window), so the pills cannot be drawn by the
/// selectable text itself. The backdrop is a second `Text` with identical
/// content, fonts, and proposed width — deterministic line breaking makes its
/// chip-run geometry pixel-identical to the foreground's.
///
/// Cost model: one extra text layout + an O(runs) walk and a few
/// `GraphicsContext` path fills, paid ONLY by runs that contain chips — no
/// extra layout passes for plain paragraphs, no AppKit views.
struct InlineCodeChipRenderer: TextRenderer {
    var background: Color
    var cornerRadius: CGFloat

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            // Consecutive chip runs on a line merge into one rect, so a chip
            // is a single pill even when attributes split it into runs. A
            // chip that wraps gets one pill per line fragment.
            var chipRect: CGRect?
            for run in line {
                if run[InlineCodeChip.self] != nil {
                    let rect = run.typographicBounds.rect
                    chipRect = chipRect?.union(rect) ?? rect
                } else if let rect = chipRect {
                    fillChip(rect, in: &context)
                    chipRect = nil
                }
            }
            if let rect = chipRect {
                fillChip(rect, in: &context)
            }
        }
    }

    private func fillChip(_ rect: CGRect, in context: inout GraphicsContext) {
        // Half-point vertical inset keeps stacked wrapped-chip pills from
        // touching across lines; the NNBSP pads already provide the
        // horizontal breathing room.
        let chip = rect.insetBy(dx: 0, dy: 0.5)
        context.fill(
            Path(roundedRect: chip, cornerRadius: min(cornerRadius, chip.height / 2)),
            with: .color(background)
        )
    }
}
