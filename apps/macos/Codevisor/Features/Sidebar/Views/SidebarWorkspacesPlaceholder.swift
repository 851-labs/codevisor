import CodevisorUI
import SwiftUI

struct SidebarWorkspacesPlaceholder: View {
  var body: some View {
    ContentUnavailableView {
      Label(WorkspaceListEmptyCopy.title, systemImage: WorkspaceListEmptyCopy.systemImage)
    } description: {
      Text(WorkspaceListEmptyCopy.message)
    }
  }
}
