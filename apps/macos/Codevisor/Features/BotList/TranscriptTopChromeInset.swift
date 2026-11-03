import SwiftUI

struct TranscriptTopChromeInset: ViewModifier, Animatable {
  var height: CGFloat

  var animatableData: CGFloat {
    get { height }
    set { height = newValue }
  }

  func body(content: Content) -> some View {
    content.environment(\.transcriptTopChromeHeight, height)
  }
}
