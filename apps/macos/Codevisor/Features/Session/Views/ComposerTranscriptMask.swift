import SwiftUI

/// Fades transcript pixels beneath the floating composer's top edge, then
/// removes them beneath the rest of the card and its bottom margin.
struct ComposerTranscriptMask: View {
  private static let fadeHeight: CGFloat = 28
  private var cardStyle = ComposerCardStyle()

  let composerSize: CGSize
  let bottomInset: CGFloat

  var body: some View {
    GeometryReader { geometry in
      Color.white
        .overlay(alignment: .bottom) {
          if composerSize.width > 0, composerSize.height > 0 {
            let holeWidth = min(composerSize.width, geometry.size.width)
            let holeHeight = composerSize.height + bottomInset

            ZStack(alignment: .bottom) {
              // Render the shape in the composer's position so SwiftUI can
              // resolve its concentric corners from the same container.
              cardStyle.shape
                .frame(height: composerSize.height)
                .padding(.bottom, bottomInset)

              // Continue the cutout through the bottom corners and margin.
              Rectangle()
                .frame(height: composerSize.height / 2 + bottomInset)
            }
            .foregroundStyle(.white)
            .frame(width: holeWidth, height: holeHeight)
            .mask {
              LinearGradient(
                stops: [
                  .init(color: .clear, location: 0),
                  .init(color: .white, location: min(Self.fadeHeight / holeHeight, 1)),
                ],
                startPoint: .top,
                endPoint: .bottom
              )
            }
            .blendMode(.destinationOut)
          }
        }
        .compositingGroup()
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}
