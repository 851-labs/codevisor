import CodevisorCore
import SwiftUI

struct HomeSidebarLiveList: View {
  @Environment(AppEnvironment.self) private var environment

  let actions: HomeSidebarActionHandler
  let splitNavigation: HomeNavigationState?

  @State private var pendingSelection: UUID?

  var body: some View {
    let sections = HomeSidebarSectionBuilder(environment: environment).sections()
    let selectedRowID = splitNavigation.flatMap { selectedRowID($0, sections: sections) }
    HomeSidebarList(
      sections: sections,
      actions: actions,
      selection: splitNavigation == nil ? nil : selection(sections: sections, selectedRowID: selectedRowID)
    )
    .onChange(of: selectedRowID) { _, _ in
      pendingSelection = nil
    }
  }

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
