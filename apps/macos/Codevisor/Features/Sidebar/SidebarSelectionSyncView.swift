import CodevisorUI
import SwiftUI

struct SidebarSelectionSyncView: View {
  let target: () -> SidebarSelectionTarget?
  let rowIDs: Set<SidebarRowID>
  let model: SidebarSelectionModel
  let scrollIfRequested: (UUID) -> Void
  @State private var awaitedScroll = AwaitedScroll()

  var body: some View {
    Color.clear
      .onChange(of: target(), initial: true) { previous, target in
        model.select(target)
        model.highlight(among: rowIDs)
        if previous == target || previous?.workspaceID != target?.workspaceID {
          awaitedScroll.workspaceID = target?.workspaceID
        }
        scrollOnceListed(in: rowIDs)
      }
      .background(
        Color.clear.onChange(of: rowIDs) { _, rowIDs in
          model.highlight(among: rowIDs)
          scrollOnceListed(in: rowIDs)
        }
      )
  }

  private func scrollOnceListed(in rowIDs: Set<SidebarRowID>) {
    guard let workspaceID = awaitedScroll.workspaceID, rowIDs.contains(.workspace(workspaceID)) else { return }

    awaitedScroll.workspaceID = nil
    scrollIfRequested(workspaceID)
  }
}

private final class AwaitedScroll {
  var workspaceID: UUID?
}
