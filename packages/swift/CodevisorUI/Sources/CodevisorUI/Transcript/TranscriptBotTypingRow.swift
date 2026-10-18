import SwiftUI

public struct TranscriptBotTypingRow: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init() {}

  public var body: some View {
    HStack {
      TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
        let phase = context.date.timeIntervalSinceReferenceDate
        HStack(spacing: 4) {
          ForEach(0..<3, id: \.self) { index in
            Circle()
              .fill(Color.secondary)
              .frame(width: 7, height: 7)
              .opacity(reduceMotion ? 0.6 : 0.35 + 0.65 * Self.pulse(phase: phase, index: index))
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Capsule(style: .continuous).fill(Color.bubbleBackground))
      }
      Spacer(minLength: 0)
    }
    .suppressedDuringStreamingTextEntrance()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Working")
  }

  private static func pulse(phase: TimeInterval, index: Int) -> Double {
    max(0, sin((phase * 2 * .pi / 1.2) - Double(index) * 0.7))
  }
}
