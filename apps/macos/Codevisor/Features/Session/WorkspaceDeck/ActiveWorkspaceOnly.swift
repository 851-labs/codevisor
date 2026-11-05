import SwiftUI

struct ActiveWorkspaceOnly<Content: View>: View {
  @ViewBuilder let content: () -> Content
  @Environment(WorkspaceActivity.self) private var activity: WorkspaceActivity?

  var body: some View {
    if activity?.isActive ?? true {
      content()
    }
  }
}
