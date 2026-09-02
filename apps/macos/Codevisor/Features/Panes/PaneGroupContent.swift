import SwiftUI

/// The selected pane's content. Selection mounts the destination immediately;
/// chat transcripts manage their own initial row-geometry reveal internally.
struct PaneGroupContent: View {
  var group: PaneGroupModel

  var body: some View {
    if let pane = group.selectedPane {
      pane.makeView()
        .id(pane.id)
    }
  }
}
