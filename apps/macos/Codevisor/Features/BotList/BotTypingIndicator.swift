import SwiftUI

struct BotTypingIndicator: View {
  private static let dotCount = 3
  private static let dotDiameter: CGFloat = 6
  private static let stepInterval: TimeInterval = 0.35

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.periodic(from: .now, by: Self.stepInterval)) { context in
      dots(lit: litDot(at: context.date))
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(.quaternary, in: .capsule)
    .accessibilityElement()
    .accessibilityLabel("Working")
  }

  private func dots(lit: Int?) -> some View {
    HStack(spacing: 3) {
      ForEach(0..<Self.dotCount, id: \.self) { index in
        Circle()
          .frame(width: Self.dotDiameter, height: Self.dotDiameter)
          .opacity(index == lit ? 1 : 0.4)
      }
    }
    .foregroundStyle(.secondary)
    .animation(.easeInOut(duration: Self.stepInterval), value: lit)
  }

  private func litDot(at date: Date) -> Int? {
    guard !reduceMotion else { return nil }

    let step = Int(date.timeIntervalSinceReferenceDate / Self.stepInterval)
    return step % Self.dotCount
  }
}
