import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarActions {
  var open: (HomeSidebarTabRow, HomeSidebarWorkspaceRef) -> Void = { _, _ in }
  var openWorkspace: (HomeSidebarWorkspace) -> Void = { _ in }
  var close: (HomeSidebarTabRow, HomeSidebarWorkspaceRef) -> Void = { _, _ in }
  var rename: (HomeSidebarTabRow, HomeSidebarWorkspaceRef) -> Void = { _, _ in }
  var newTab: (HomeSidebarWorkspaceRef) -> Void = { _ in }
  var newChat: (NewChatTarget) -> Void = { _ in }
  var togglePin: (HomeSidebarWorkspaceRef) -> Void = { _ in }
  var renameWorkspace: (HomeSidebarWorkspaceRef) -> Void = { _ in }
  var archiveWorkspace: (HomeSidebarWorkspaceRef) -> Void = { _ in }
  var restoreWorkspace: (HomeSidebarWorkspaceRef) -> Void = { _ in }
  var reorder: (UUID, Int, [UUID]) -> Void = { _, _, _ in }
  var moveTab: (UUID, UUID?, HomeSidebarWorkspaceRef) -> Void = { _, _, _ in }
  var openInNewWindow: ((HomeSidebarTabRow, HomeSidebarWorkspaceRef) -> Void)?
  var openWorkspaceInNewWindow: ((HomeSidebarWorkspace) -> Void)?
  var didSelectInSplit: () -> Void = {}
  var refresh: () async -> Void = {}
}

@MainActor
final class HomeSidebarActionHandler {
  var actions: HomeSidebarActions

  init(_ actions: HomeSidebarActions) {
    self.actions = actions
  }
}

struct HomeSidebarSelection: Equatable {
  let workspaceId: UUID
  let paneId: UUID?
}

struct HomeSidebarList: View {
  static let expandedWorkspacesKey = "ios.sidebar.expandedWorkspaces"

  let makeContent: (HomeSidebarPreferences) -> HomeSidebarContent
  let actions: HomeSidebarActionHandler
  var isSelectable = false
  var selected: HomeSidebarSelection? = nil
  var refreshDetails: ([UUID], [SidebarRowDetail]) -> Void = { _, _ in }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @ClientPreference(SidebarGrouping.preferenceKey, default: SidebarGrouping.flat) private var grouping
  @ClientPreference(SidebarGrouping.collapsedPreferenceKey, default: []) private var collapsedGroupIDs: [String]
  @ClientPreference(SidebarPreferenceKey.pinnedWorkspaces, default: []) private var pinnedIDs: [String]
  @ClientPreference(SidebarRowDetail.preferenceKey, default: SidebarRowDetail.defaults)
  private var rowDetails: [SidebarRowDetail]
  @ClientPreference(SidebarPreferenceKey.pinnedExpanded, default: true) private var pinnedExpanded
  @ClientPreference(SidebarPreferenceKey.listExpanded, default: true) private var listExpanded
  @ClientPreference(SidebarPreferenceKey.archivedExpanded, default: false) private var archivedExpanded
  @ClientPreference(Self.expandedWorkspacesKey, default: []) private var expandedWorkspaceIDs: [String]
  @State private var archivedLimit = sidebarArchivedPageSize
  @State private var pendingSelection: UUID?

  private var preferences: HomeSidebarPreferences {
    HomeSidebarPreferences(
      grouping: grouping, pinnedIDs: pinnedIDs, rowDetails: rowDetails, archivedLimit: archivedLimit)
  }

  var body: some View {
    let content = makeContent(preferences)
    list(content)
      .listStyle(.sidebar)
      .animation(Motion.listReflow(reduceMotion: reduceMotion), value: content)
      .onChange(of: selected) { _, _ in
        pendingSelection = nil
      }
      .refreshable {
        await actions.actions.refresh()
      }
      .task(id: SidebarGitLookups.refreshKey(details: rowDetails, workspaceIds: detailedWorkspaceIDs(content))) {
        let ids = detailedWorkspaceIDs(content)
        guard SidebarGitLookups.refreshKey(details: rowDetails, workspaceIds: ids) != nil else { return }
        while !Task.isCancelled {
          refreshDetails(ids, rowDetails)
          try? await Task.sleep(for: .seconds(60))
        }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { refreshDetails(detailedWorkspaceIDs(content), rowDetails) }
      }
  }

  private func detailedWorkspaceIDs(_ content: HomeSidebarContent) -> [UUID] {
    let listed = content.pinned + content.groups.flatMap(\.workspaces)
    return (listed + (archivedExpanded ? content.archived : [])).map(\.id)
  }

  @ViewBuilder
  private func list(_ content: HomeSidebarContent) -> some View {
    if isSelectable {
      List(selection: selection(content)) {
        sections(content)
      }
    } else {
      List {
        sections(content)
      }
    }
  }

  @ViewBuilder
  private func sections(_ content: HomeSidebarContent) -> some View {
    if !content.pinned.isEmpty {
      Section("Pinned", isExpanded: animated($pinnedExpanded)) {
        workspaceRows(content.pinned)
      }
    }
    Section(content.listTitle, isExpanded: animated($listExpanded)) {
      ForEach(content.groups) { group in
        if let heading = group.heading {
          DisclosureGroup(isExpanded: groupExpansion(group.id)) {
            workspaceRows(group.workspaces)
          } label: {
            HomeSidebarGroupLabel(
              heading: heading,
              onNewChat: heading.newChatTarget.map { target in { actions.actions.newChat(target) } }
            )
          }
        } else {
          workspaceRows(group.workspaces)
        }
      }
      if content.groups.allSatisfy(\.workspaces.isEmpty) {
        Text("No Workspaces")
          .foregroundStyle(.tertiary)
      }
    }
    if content.archivedCount > 0 {
      Section("Archived", isExpanded: animated($archivedExpanded)) {
        ForEach(content.archived) { workspace in
          HomeSidebarWorkspaceRowView(workspace: workspace, actions: actions, isSelectionRow: isSelectable)
            .equatable()
        }
        if content.archivedCount > content.archived.count {
          Button("Show More") {
            withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
              archivedLimit += sidebarArchivedPageSize
            }
          }
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func workspaceRows(_ workspaces: [HomeSidebarWorkspace]) -> some View {
    ForEach(workspaces) { workspace in
      workspaceRow(workspace)
    }
    .onMove { source, destination in
      guard let index = source.first else { return }
      let target = destination > index ? destination - 1 : destination
      actions.actions.reorder(workspaces[index].id, target, workspaces.map(\.id))
    }
  }

  @ViewBuilder
  private func workspaceRow(_ workspace: HomeSidebarWorkspace) -> some View {
    let row = HomeSidebarWorkspaceRowView(workspace: workspace, actions: actions, isSelectionRow: isSelectable)
      .equatable()
      .tag(workspace.id)
    if workspace.rows.isEmpty {
      row
    } else {
      DisclosureGroup(isExpanded: workspaceExpansion(workspace.id)) {
        tabRows(workspace)
      } label: {
        row
      }
    }
  }

  private func tabRows(_ workspace: HomeSidebarWorkspace) -> some View {
    let ref = workspace.workspace
    return ForEach(workspace.rows) { row in
      HomeSidebarTabRowView(row: row, workspace: ref, actions: actions, isSelectionRow: isSelectable)
        .equatable()
        .tag(row.id)
    }
    .onMove { source, destination in
      moveTab(in: workspace, from: source, to: destination)
    }
  }

  private func moveTab(in workspace: HomeSidebarWorkspace, from source: IndexSet, to destination: Int) {
    guard let row = source.first, let tabId = workspace.rows[row].tabId else { return }
    let rowTabIds = workspace.rows.map { $0.tabId ?? $0.id }
    let successor = SharedTabOrder.successor(of: tabId, droppedAt: destination, rowTabIds: rowTabIds)
    actions.actions.moveTab(tabId, successor, workspace.workspace)
  }

  private func animated(_ binding: Binding<Bool>) -> Binding<Bool> {
    binding.animation(Motion.listReflow(reduceMotion: reduceMotion))
  }

  private func groupExpansion(_ id: String) -> Binding<Bool> {
    animated(
      Binding(
        get: { !collapsedGroupIDs.contains(id) },
        set: { isExpanded in
          collapsedGroupIDs.removeAll { $0 == id }
          if !isExpanded { collapsedGroupIDs.append(id) }
        }
      ))
  }

  private func workspaceExpansion(_ id: UUID) -> Binding<Bool> {
    let key = id.uuidString
    return animated(
      Binding(
        get: { expandedWorkspaceIDs.contains(key) },
        set: { isExpanded in
          expandedWorkspaceIDs.removeAll { $0 == key }
          if isExpanded { expandedWorkspaceIDs.append(key) }
        }
      ))
  }

  private func selectedRowID(_ content: HomeSidebarContent) -> UUID? {
    guard let selected else { return nil }
    if let paneId = selected.paneId, expandedWorkspaceIDs.contains(selected.workspaceId.uuidString),
      content.row(paneId) != nil
    {
      return paneId
    }
    return selected.workspaceId
  }

  private func selection(_ content: HomeSidebarContent) -> Binding<UUID?> {
    Binding(
      get: { pendingSelection ?? selectedRowID(content) },
      set: { id in
        guard let id else { return }
        if let (row, workspace) = content.row(id) {
          pendingSelection = id
          actions.actions.open(row, workspace.workspace)
        } else if let workspace = content.workspace(id) {
          pendingSelection = id
          actions.actions.openWorkspace(workspace)
        } else {
          return
        }
        actions.actions.didSelectInSplit()
      }
    )
  }
}
