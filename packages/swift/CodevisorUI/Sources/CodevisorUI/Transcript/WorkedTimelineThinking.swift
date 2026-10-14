import SwiftUI

struct WorkedTimelineThinking: View {
  let isFirst: Bool

  var body: some View {
    WorkedTimelineRail(isFirst: isFirst, isLast: true) {
      Circle()
        .fill(.secondary)
        .frame(width: 5, height: 5)
    } line: {
      Text("Thinking")
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .shimmering()
        .frame(maxWidth: .infinity, alignment: .leading)
    } expanded: {
      EmptyView()
    }
  }
}
