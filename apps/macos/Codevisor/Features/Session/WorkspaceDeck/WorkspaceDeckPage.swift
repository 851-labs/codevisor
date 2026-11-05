import SwiftUI

struct WorkspaceDeckPage<Content: View>: View, Equatable {
  let route: WorkspaceDeckRoute
  let activity: WorkspaceActivity
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .environment(activity)
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.route == rhs.route && lhs.activity === rhs.activity
  }
}
