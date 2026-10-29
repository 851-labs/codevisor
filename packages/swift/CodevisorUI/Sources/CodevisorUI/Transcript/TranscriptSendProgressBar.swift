import SwiftUI

struct TranscriptSendProgressBar: View {
  private static let size = CGSize(width: 48, height: 4)
  private static let gapBelowBubble: CGFloat = 3
  private static let startFraction: CGFloat = 0.12
  private static let endFraction: CGFloat = 0.9
  private static let creep = Animation.easeOut(duration: 12)

  @Environment(\.userBubbleStyle) private var style
  @State private var fraction = Self.startFraction

  private var progressFill: Color {
    style == .accent ? style.fill : .secondary
  }

  var body: some View {
    Capsule()
      .fill(Color.secondary.opacity(0.25))
      .overlay(alignment: .leading) {
        Capsule()
          .fill(progressFill)
          .frame(width: Self.size.width * fraction)
      }
      .frame(width: Self.size.width, height: Self.size.height)
      .padding(.top, Self.gapBelowBubble)
      .onAppear {
        withAnimation(Self.creep) { fraction = Self.endFraction }
      }
      .accessibilityElement()
      .accessibilityLabel("Sending")
  }
}
