import SwiftUI

struct WorkspaceRowTrailing: View {
  let details: WorkspaceRowDetails
  let lifecycle: WorkspaceRowLifecycle
  let isHovered: Bool

  var body: some View {
    if isHovered {
      WorkspaceRowHoverActions(lifecycle: lifecycle, title: details.title)
        .hidden()
    } else {
      WorkspaceRowProperties(details: details, isArchived: lifecycle.isArchived)
    }
  }
}
