import SwiftUI
import CodevisorCore
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

/// Fades transcript pixels beneath the floating composer's top edge, then
/// removes them beneath the rest of the card and its bottom margin.
struct ComposerTranscriptMask: View {
  private static let fadeHeight: CGFloat = 28

  let composerSize: CGSize
  let bottomInset: CGFloat

  var body: some View {
    Canvas { context, size in
      var visibleArea = Path()
      visibleArea.addRect(CGRect(origin: .zero, size: size))

      if composerSize.width > 0, composerSize.height > 0 {
        let holeWidth = min(composerSize.width, size.width)
        let holeHeight = min(composerSize.height + bottomInset, size.height)
        let holeRect = CGRect(
          x: (size.width - holeWidth) / 2,
          y: size.height - holeHeight,
          width: holeWidth,
          height: holeHeight
        )
        let holeShape = UnevenRoundedRectangle(
          topLeadingRadius: ComposerCard.cornerRadius,
          topTrailingRadius: ComposerCard.cornerRadius
        )
        let holePath = holeShape.path(in: holeRect)
        visibleArea.addPath(holePath)

        let fadeEndY = holeRect.minY + min(Self.fadeHeight, holeRect.height)
        context.fill(
          holePath,
          with: .linearGradient(
            Gradient(colors: [.white, .clear]),
            startPoint: CGPoint(x: holeRect.midX, y: holeRect.minY),
            endPoint: CGPoint(x: holeRect.midX, y: fadeEndY)
          )
        )
      }

      context.fill(
        visibleArea,
        with: .color(.white),
        style: FillStyle(eoFill: true)
      )
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}
