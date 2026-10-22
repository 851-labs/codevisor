import SwiftUI

struct FirstLaunchStepDetail: View {
  let candidates: [String]
  let count: Int?

  var body: some View {
    ViewThatFits(in: .horizontal) {
      ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
        Text(candidate)
          .lineLimit(1)
          .contentTransition(transition)
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .opacity(candidates.isEmpty ? 0 : 1)
    .animation(.smooth(duration: 0.18), value: candidates)
  }

  private var transition: ContentTransition {
    guard let count else { return .opacity }
    return .numericText(value: Double(count))
  }
}
