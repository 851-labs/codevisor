#if !canImport(AppKit)
  import SwiftUI

  struct InlineCodeChipMarker: TextAttribute {}

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
          return Text("\(text)\(piece.isChip ? segment.customAttribute(InlineCodeChipMarker()) : segment)")
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
