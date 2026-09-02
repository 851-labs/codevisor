// The pure-SwiftUI inline-code chip painter used by portable renderers such
// as iOS table cells. Native transcript prose uses the matching TextKit chip
// background painter.
#if !canImport(AppKit)
  import SwiftUI

  /// SwiftUI-side marker mirroring `InlineCodeChipAttribute`: attached to the
  /// chip Text segments so the renderer can find their glyph runs.
  struct InlineCodeChipMarker: TextAttribute {}

  /// Paints rounded chip backgrounds behind marked runs, then draws the text.
  /// Consecutive chip runs on one line merge into a single chip (the code span
  /// plus its narrow no-break pads).
  struct InlineCodeChipRenderer: TextRenderer {
    let chipColor: Color
    let cornerRadius: CGFloat

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
      for line in layout {
        var chipRect: CGRect?
        func flush() {
          if let rect = chipRect {
            context.fill(
              Path(roundedRect: rect.insetBy(dx: -1, dy: 0.5), cornerRadius: cornerRadius),
              with: .color(chipColor)
            )
          }
          chipRect = nil
        }
        for run in line {
          if run[InlineCodeChipMarker.self] != nil {
            let rect = run.typographicBounds.rect
            chipRect = chipRect.map { $0.union(rect) } ?? rect
          } else {
            flush()
          }
        }
        flush()
      }
      for line in layout {
        context.draw(line)
      }
    }
  }

  /// Inline markdown as SwiftUI Text with chip backgrounds. Plain text takes
  /// the cheap single-Text path; only strings containing code spans pay for
  /// segment concatenation and the renderer.
  @ViewBuilder
  func portableInlineText(_ markdown: String, theme: MarkdownTheme) -> some View {
    portableInlineText(MarkdownParser().parseInline(markdown), theme: theme)
  }

  @ViewBuilder
  func portableInlineText(_ markdown: MarkdownText, theme: MarkdownTheme) -> some View {
    let attributed = InlineMarkdown.attributedString(from: markdown, theme: theme)
    let pieces = InlineMarkdown.chipPieces(in: attributed)
    if pieces.contains(where: { $0.isChip }) {
      pieces
        .reduce(Text("")) { text, piece in
          let segment = Text(piece.text)
          return text + (piece.isChip ? segment.customAttribute(InlineCodeChipMarker()) : segment)
        }
        .textRenderer(
          InlineCodeChipRenderer(
            chipColor: theme.inlineCodeBackground,
            cornerRadius: theme.inlineCodeCornerRadius
          )
        )
    } else {
      Text(attributed)
    }
  }
#endif
