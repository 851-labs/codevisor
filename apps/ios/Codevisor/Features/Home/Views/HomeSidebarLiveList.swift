import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarLiveList: View {
  @Environment(AppEnvironment.self) private var environment

  let actions: HomeSidebarActionHandler
  let splitNavigation: HomeNavigationState?
  let gitLookups: SidebarGitLookups
  let mode: Binding<SidebarMode>

  var body: some View {
    let builder = HomeSidebarContentBuilder(environment: environment, gitLookups: gitLookups)
    HomeSidebarList(
      makeContent: builder.content,
      actions: actions,
      isSelectable: splitNavigation != nil,
      selected: splitNavigation.flatMap(selected),
      mode: resolved(mode),
      refreshDetails: refreshDetails
    )
  }

  private func resolved(_ mode: Binding<SidebarMode>) -> Binding<SidebarMode> {
    let active = mode.wrappedValue
    return Binding(get: { active }, set: { mode.wrappedValue = $0 })
  }

  private func refreshDetails(_ ids: [UUID], details: [SidebarRowDetail]) {
    let builder = HomeSidebarContentBuilder(environment: environment, gitLookups: gitLookups)
    let workspaces = ids.compactMap { environment.navigationStore.workspaceEntries.entry($0).workspace }
    gitLookups.refresh(
      active: workspaces.filter { !$0.isArchived },
      archived: workspaces.filter(\.isArchived),
      listedIds: builder.listedItems.map(\.id),
      details: details,
      client: environment.machines.client(for:)
    )
  }

  private func selected(_ navigation: HomeNavigationState) -> HomeSidebarSelection? {
    if case let .bot(_, botId) = navigation.selection { return .bot(botId) }
    guard let presented = navigation.presentedWorkspace else { return nil }
    let workspace = environment.navigationStore.workspaceEntries.entry(presented.workspaceId).workspace
    if let tab = workspace?.selectedCenterTab,
      let paneId = tab.root.group(id: tab.activeLeafId)?.selectedPaneId
    {
      return .workspace(presented.workspaceId, paneId: paneId)
    }
    let paneId = navigation.selectedPaneId { chatId in
      workspace?.centerTabs.lazy
        .flatMap { $0.root.allGroups.flatMap(\.state.panes) }
        .first { $0.chatSessionId == chatId }?.id
    }
    return .workspace(presented.workspaceId, paneId: paneId)
  }
}
