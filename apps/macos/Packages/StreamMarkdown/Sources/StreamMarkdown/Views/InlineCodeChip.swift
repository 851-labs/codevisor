import SwiftUI

/// Marks a run of a parsed `AttributedString` as an inline-code chip.
/// `InlineMarkdown.styleInlineCode` sets it; `Text.withInlineCodeChips`
/// translates it into the SwiftUI `TextAttribute` the renderer draws.
enum InlineCodeChipKey: AttributedStringKey {
    typealias Value = Bool
    static let name = "herdman.inlineCodeChip"
}

/// The `TextAttribute` the chip renderer looks for on layout runs.
///
/// The `marker` payload is intentional. A zero-sized (empty) `TextAttribute`
/// is not reliably matched on `Text.Layout` runs in optimized release builds,
/// so the chip fill was silently skipped in production while the glyphs still
/// drew — inline code lost its background only in the shipped (Release) app.
struct InlineCodeChipAttribute: TextAttribute {
    var marker = true
}

extension Text {
    /// Builds a `Text` from an attributed string, tagging inline-code runs
    /// with `InlineCodeChipAttribute` so `InlineCodeChipRenderer` can draw
    /// rounded chip backgrounds behind them. Concatenated `Text` stays a
    /// single view, so multi-block selection keeps working.
    static func withInlineCodeChips(_ attributed: AttributedString) -> Text {
        guard attributed.runs.contains(where: { $0[InlineCodeChipKey.self] == true }) else {
            return Text(attributed)
        }
        var text = Text(verbatim: "")
        for run in attributed.runs {
            let piece = AttributedString(attributed[run.range])
            if run[InlineCodeChipKey.self] == true {
                text = Text("\(text)\(Text(piece).customAttribute(InlineCodeChipAttribute()))")
            } else {
                text = Text("\(text)\(Text(piece))")
            }
        }
        return text
    }
}

/// Draws rounded-rect chip backgrounds behind inline-code runs, then renders
/// the text on top. Vertical padding extends the chip past the glyph bounds
/// without inflating line height; horizontal padding comes from the narrow
/// no-break spaces `InlineMarkdown` adds around each code span.
struct InlineCodeChipRenderer: TextRenderer {
    var background: Color
    var cornerRadius: CGFloat = 4
    var verticalPadding: CGFloat = 1.5
    /// When false, only the chip backgrounds are painted; the glyphs are left
    /// to a separate, selectable text layer. This keeps the renderer off the
    /// same view as `.textSelection(.enabled)`, which suppresses custom text
    /// renderers in release builds (the chip fill silently stops running).
    var drawsGlyphs = true

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            // The pad spaces and the code text carry different attributes, so
            // one chip arrives as several adjacent runs. Union contiguous chip
            // runs into a single rect, else each fragment draws its own
            // rounded corners.
            var chip = CGRect.null
            func flush() {
                guard !chip.isNull else { return }
                let rect = chip.insetBy(dx: 0, dy: -verticalPadding)
                context.fill(
                    RoundedRectangle(cornerRadius: cornerRadius).path(in: rect),
                    with: .color(background)
                )
                chip = .null
            }
            for run in line {
                guard run[InlineCodeChipAttribute.self] != nil else {
                    flush()
                    continue
                }
                let bounds = run.reduce(CGRect.null) { $0.union($1.typographicBounds.rect) }
                chip = chip.union(bounds)
            }
            flush()
            if drawsGlyphs {
                context.draw(line)
            }
        }
    }
}
