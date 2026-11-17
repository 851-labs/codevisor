import CodevisorUI
import SwiftUI

struct WorkspaceDeckPage<Content: View>: View, Equatable {
  let route: WorkspaceDeckRoute
  let activity: WorkspaceActivity
  let model: WorkspacePageModel
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .environment(activity)
      .environment(model)
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.route == rhs.route && lhs.activity === rhs.activity && lhs.model === rhs.model
  }
}
