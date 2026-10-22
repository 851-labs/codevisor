import SwiftUI

struct FirstLaunchStepDetail: View {
  let candidates: [String]

  var body: some View {
    ViewThatFits(in: .horizontal) {
      ForEach(candidates, id: \.self) { candidate in
        Text(candidate)
          .lineLimit(1)
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .opacity(candidates.isEmpty ? 0 : 1)
    .animation(.smooth(duration: 0.3), value: candidates)
  }
}
