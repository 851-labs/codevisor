import SwiftUI

struct FirstLaunchStepDetail: View {
  let candidates: [String]

  var body: some View {
    ViewThatFits(in: .horizontal) {
      ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
        Text(candidate)
          .lineLimit(1)
          .contentTransition(.opacity)
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .opacity(candidates.isEmpty ? 0 : 1)
    .animation(.smooth(duration: 0.18), value: candidates)
  }
}
