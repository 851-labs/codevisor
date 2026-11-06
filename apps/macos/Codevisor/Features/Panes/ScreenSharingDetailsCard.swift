import SwiftUI

struct ScreenSharingDetailsCard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    WorkspaceInspectorCardRows { content }
      .background(Color.primary.opacity(0.034), in: WorkspaceInspectorCardShape.card)
  }
}
