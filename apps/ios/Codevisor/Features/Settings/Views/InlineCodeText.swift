import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import os

struct InlineCodeText: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  private struct ChipMarker: TextAttribute {}

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
          return Text("\(result)\(Text(piece.element))")
        }
        let chip = Text(piece.element)
          .font(.footnote.monospaced())
          .customAttribute(ChipMarker())
        return Text("\(result)\(chip)")
      }
      .textRenderer(ChipRenderer())
  }
}
