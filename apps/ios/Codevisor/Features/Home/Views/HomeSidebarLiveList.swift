import CodevisorCore
import SwiftUI

/// The fleet's sidebar: builds the sections from Core's precomputed sidebar
/// and owns the split layout's selection.
///
/// Its own view so the sidebar's dependencies -- every listed workspace, the
/// chats' titles and statuses -- re-render only the sidebar, never Home and
/// the workspace beside it. Its inputs are a stable handler and plain
/// values, so Home re-rendering leaves it alone unless the route changed.
struct HomeSidebarLiveList: View {
  @Environment(AppEnvironment.self) private var environment

  let actions: HomeSidebarActionHandler
  /// The split layout's navigation, whose route the selection follows. Nil
  /// on the phone's stack, where the list is buttons that push.
  let splitNavigation: HomeNavigationState?

  /// A sidebar tap the workspace has not recorded as its selection yet, so
  /// the highlight lands on the tapped row without flicking back first.
  @State private var pendingSelection: UUID?

  var body: some View {
    let sections = HomeSidebarSectionBuilder(environment: environment).sections()
    let selectedRowID = splitNavigation.flatMap { selectedRowID($0, sections: sections) }
    HomeSidebarList(
      sections: sections,
      actions: actions,
      selection: splitNavigation == nil ? nil : selection(sections: sections, selectedRowID: selectedRowID)
    )
    // The workspace recorded the tap as its selection; the pending value
    // has done its job.
    .onChange(of: selectedRowID) { _, _ in
      pendingSelection = nil
    }
  }

  /// Reading follows what the detail shows; writing opens the tab through
  /// the same path a phone row takes.
  private func selection(sections: [HomeSidebarSection], selectedRowID: UUID?) -> Binding<UUID?> {
    Binding(
      get: { pendingSelection ?? selectedRowID },
      set: { id in
        guard let id,
          let section = sections.first(where: { $0.rows.contains { $0.id == id } }),
          let row = section.rows.first(where: { $0.id == id })
        else { return }
        pendingSelection = id
        actions.actions.open(row, section.workspace)
        actions.actions.didSelectInSplit()
      }
    )
  }

  /// The pane row highlighted as the split selection. The presented
  /// workspace's persisted selection is what the detail actually shows, so
  /// it wins: a New Tab, a conversion, a close, or an agent navigating the
  /// workspace all move it without changing Home's route. The route only
  /// stands in before the workspace has recorded a selection.
  private func selectedRowID(_ navigation: HomeNavigationState, sections: [HomeSidebarSection]) -> UUID? {
    if let presented = navigation.presentedWorkspace,
      let workspace = environment.navigationStore.workspaceEntries.entry(presented.workspaceId).workspace,
      let tab = workspace.selectedCenterTab,
      let paneId = tab.root.group(id: tab.activeLeafId)?.selectedPaneId
    {
      return paneId
    }
    return navigation.selectedPaneId { chatId in
      sections.lazy.flatMap(\.rows).first { $0.chatSessionId == chatId }?.id
    }
  }
}
