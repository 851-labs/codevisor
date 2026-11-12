import SwiftUI

struct WorkspaceRowProperties: View {
  let details: WorkspaceRowDetails
  let isArchived: Bool

  var body: some View {
    SidebarWorkspaceRowProperties(pullRequest: details.pullRequest, machine: details.machine)
      .opacity(isArchived ? WorkspaceRow.archivedOpacity : 1)
  }
}
