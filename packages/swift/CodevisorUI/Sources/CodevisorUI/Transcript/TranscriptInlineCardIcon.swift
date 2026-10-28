import SwiftUI

struct TranscriptInlineCardIcon: View {
  let image: Image

  var body: some View {
    image
      .resizable()
      .interpolation(.high)
      .frame(width: TranscriptInlineCardMetrics.iconSize, height: TranscriptInlineCardMetrics.iconSize)
      .accessibilityHidden(true)
  }
}
