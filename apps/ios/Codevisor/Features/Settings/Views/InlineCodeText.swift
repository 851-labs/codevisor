import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

// MARK: - Inline code styling

/// Styles the backticked runs of a hint string like chat history's inline
/// code chips — monospaced over a soft rounded background — so commands read
/// as code instead of just a font change. Uses the same TextRenderer
/// technique as StreamMarkdown's portable chip painter.
struct InlineCodeText: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  /// Marks the code-span glyph runs so the renderer can find them.
  private struct ChipMarker: TextAttribute {}

  /// Paints a rounded chip behind every marked run, then draws the text.
  private struct ChipRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
      for line in layout {
        var chipRect: CGRect?
        func flush() {
          if let rect = chipRect {
            context.fill(
              Path(roundedRect: rect.insetBy(dx: -3, dy: -1), cornerRadius: 5),
              with: .color(Color.secondary.opacity(0.18))
            )
          }
          chipRect = nil
        }
        for run in line {
          if run[ChipMarker.self] != nil {
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

  var body: some View {
    Array(text.components(separatedBy: "`").enumerated())
      .reduce(Text("")) { result, piece in
        if piece.offset.isMultiple(of: 2) {
          return result + Text(piece.element)
        }
        return result
          + Text(piece.element)
          .font(.footnote.monospaced())
          .customAttribute(ChipMarker())
      }
      .textRenderer(ChipRenderer())
  }
}
