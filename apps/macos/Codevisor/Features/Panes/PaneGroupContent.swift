import SwiftUI
import CodevisorCore

/// Selection presents its shell before constructing cold native content.
/// Each pane then owns its loading state; readiness never gates navigation.
struct PaneGroupContent: View {
  var group: PaneGroupModel

  var body: some View {
    if let descriptor = group.state.selectedPane {
      PaneContentMount(group: group, paneId: descriptor.id)
        .id("\(descriptor.id):\(descriptor.kind.rawValue)")
    }
  }
}

private struct PaneContentMount: View {
  let group: PaneGroupModel
  let paneId: UUID
  @State private var canMount = false

  var body: some View {
    Group {
      if canMount || group.presentedPaneIDs.contains(paneId) {
        if let pane = group.selectedPane, pane.id == paneId {
          pane.makeView()
            .onAppear { group.paneContentDidMount(id: paneId) }
        }
      } else {
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: paneId) {
      guard !group.presentedPaneIDs.contains(paneId) else { return }
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(16))
      guard !Task.isCancelled, group.state.selectedPaneId == paneId else { return }
      canMount = true
    }
  }
}
