import SwiftUI
import CodevisorCore
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

/// Removes transcript pixels beneath the floating composer and its bottom
/// margin so the full card sits over the chat panel's backing surface.
struct ComposerTranscriptMask: View {
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
                visibleArea.addPath(holeShape.path(in: holeRect))
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
