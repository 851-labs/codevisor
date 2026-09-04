import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

/// Validated add from a confirmed deeplink: unreachable hosts and
/// rejected tokens surface in the error alert instead of as a broken
/// machine. Success selects the machine, which also closes onboarding.
// MARK: - Lists

extension HomeView {
  /// Keep pull to refresh available in every connected-machine state. A
  /// refresh action only installs a refresh control when it reaches a
  /// supported scroll container, so loading, empty, and unavailable states
  /// each need a real ScrollView rather than a static replacement view.
  @ViewBuilder
  var refreshableNavigationContent: some View {
    if hasNavigationContent {
      // Unavailable machines contribute no cached content.
      sessionList
    } else if anyMachineSynced {
      // At least one machine answered with a real (empty) list: the
      // honest presentation is "no chats"; the alert names stragglers.
      refreshableState(allowsStateHitTesting: false) {
        emptyState
      }
    } else if !failedSyncMachines.isEmpty {
      // Keep the list blank instead of showing stale cached rows.
      // The native alert explains the failure and opens machine settings.
      refreshableState(allowsStateHitTesting: false) {
        EmptyView()
      }
    } else if initialSyncDeadlineExpired {
      refreshableState {
        HomeNavigationSyncView(
          state: .failed(machineName: failedSyncMachineNames),
          retry: {
            initialSyncDeadlineExpired = false
            retryFailedMachines()
          }
        )
      }
    } else if initialSyncPending {
      // Nothing cached yet: the one legitimate spinner — and even it
      // may not outlive its budget.
      refreshableState(allowsStateHitTesting: false) {
        HomeNavigationSyncView(
          state: .loading(machineName: failedSyncMachineNames)
        )
      }
      // Constant identity: the clock starts when the branch appears
      // and survives machine-list churn (cloud statuses landing used
      // to recreate the task and reset the budget forever).
      .task(id: "initial-sync-deadline") {
        initialSyncDeadlineExpired = false
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled else { return }
        initialSyncDeadlineExpired = true
      }
    } else {
      refreshableState(allowsStateHitTesting: false) {
        emptyState
      }
    }
  }

  @ViewBuilder
  private var sessionList: some View {
    if let groupReorderOrganization {
      groupReorderList(for: groupReorderOrganization)
    } else {
      navigationList
    }
  }

  private var navigationList: some View {
    List {
      switch organization {
      case .compact:
        Section {
          ForEach(visibleSessions) { session in
            chatRow(
              session,
              projectName: projectName(for: session),
              hidesBottomSeparator: session.id == visibleSessions.last?.id
            )
          }
          .onMove(perform: agentMoveAction(for: visibleSessions))
        }
        .listSectionSeparator(.visible, edges: .top)
      case .byWorkspace:
        Section {
          ForEach(workspaceItems) { item in
            workspaceDisclosure(
              item,
              isFinalRootItem: item.id == workspaceItems.last?.id
            )
          }
        }
      case .byProject:
        Section {
          ForEach(projectItems) { item in
            projectDisclosure(
              item,
              isFinalRootItem: looseProjectSessions.isEmpty
                && item.id == projectItems.last?.id
            )
          }
          // Scratch-backed and orphaned chats share one "No project"
          // row rather than each single-use folder posing as a project.
          if !looseProjectSessions.isEmpty {
            noProjectDisclosure
          }
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Color(.systemBackground))
    .refreshable {
      await refreshNavigation()
    }
    .onChange(of: organizationRaw) { _, _ in
      clearGroupReorderPresentation()
    }
  }

  /// A deliberately flat edit-mode list keeps native move handles and
  /// animations independent from the disclosure hierarchy.
  @ViewBuilder
  private func groupReorderList(for organization: HomeOrganization) -> some View {
    List {
      Section {
        switch organization {
        case .byWorkspace:
          ForEach(workspaceItems) { item in
            WorkspaceDisclosureLabel(
              workspace: item.workspace,
              status: status(for: item),
              showsStatus: true,
              machineName: machines.fleetMachineName(for: item.workspace.serverId)
            )
            .modifier(
              BottomSeparatorModifier(
                isHidden: item.id == workspaceItems.last?.id
              )
            )
          }
          .onMove(perform: moveWorkspaces)
        case .byProject:
          ForEach(projectItems) { item in
            ProjectDisclosureLabel(
              group: item.group,
              status: status(for: item),
              showsStatus: true
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(
              BottomSeparatorModifier(
                isHidden: item.id == projectItems.last?.id
              )
            )
          }
          .onMove(perform: moveProjects)
        case .compact:
          EmptyView()
        }
      }
      .listSectionSeparator(.visible, edges: .top)
    }
    .environment(\.editMode, .constant(.active))
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Color(.systemBackground))
    .contentMargins(.bottom, 24, for: .scrollContent)
    .refreshable {
      await refreshNavigation()
    }
  }

  /// Workspaces use the same native grouping pattern as projects. Collapsed
  /// labels summarize their most important child status; expanded labels
  /// leave status ownership to their direct agent children.
  private func workspaceDisclosure(
    _ item: HomeWorkspaceListItem,
    isFinalRootItem: Bool
  ) -> some View {
    let isReorderingGroups = groupReorderOrganization == .byWorkspace
    let isExpanded = !isReorderingGroups && expandedWorkspaces.contains(item.id)
    return DisclosureGroup(
      isExpanded: Binding(
        get: {
          groupReorderOrganization != .byWorkspace
            && expandedWorkspaces.contains(item.id)
        },
        set: { isExpanded in
          guard groupReorderOrganization != .byWorkspace else { return }
          setWorkspace(item.id, isExpanded: isExpanded)
        }
      )
    ) {
      ForEach(item.sessions) { session in
        chatRow(
          session,
          projectName: item.project?.name,
          hidesBottomSeparator: isFinalRootItem
            && session.id == item.sessions.last?.id
        )
      }
      .onMove(perform: agentMoveAction(for: item.sessions))
      if item.sessions.isEmpty {
        Text("No tabs yet")
          .font(.subheadline)
          .foregroundStyle(.tertiary)
          .listRowSeparator(
            isFinalRootItem ? .hidden : .visible,
            edges: .bottom
          )
      }
    } label: {
      WorkspaceDisclosureLabel(
        workspace: item.workspace,
        status: status(for: item),
        showsStatus: !isExpanded,
        machineName: machines.fleetMachineName(for: item.workspace.serverId)
      )
      .contentShape(Rectangle())
      .onTapGesture {
        guard groupReorderOrganization != .byWorkspace else { return }
        setWorkspace(item.id, isExpanded: !isExpanded)
      }
    }
    .tint(isReorderingGroups ? .clear : nil)
    .swipeActions(edge: .trailing) {
      Button {
        environment.archiveWorkspace(item.workspace)
        workspaceRevision += 1
      } label: {
        Label("Archive", systemImage: "archivebox")
      }
      .tint(.orange)
    }
    .modifier(
      BottomSeparatorModifier(isHidden: isFinalRootItem && !isExpanded)
    )
  }

  private func projectDisclosure(
    _ item: HomeProjectListItem,
    isFinalRootItem: Bool
  ) -> some View {
    let isReorderingGroups = groupReorderOrganization == .byProject
    let isExpanded = !isReorderingGroups && expandedProjects.contains(item.id)
    return DisclosureGroup(
      isExpanded: Binding(
        get: {
          groupReorderOrganization != .byProject
            && expandedProjects.contains(item.id)
        },
        set: { isExpanded in
          guard groupReorderOrganization != .byProject else { return }
          setProject(item.id, isExpanded: isExpanded)
        }
      )
    ) {
      ForEach(item.sessions) { session in
        chatRow(
          session,
          projectName: nil,
          hidesBottomSeparator: isFinalRootItem
            && session.id == item.sessions.last?.id
        )
      }
      .onMove(perform: agentMoveAction(for: item.sessions))
    } label: {
      ProjectDisclosureLabel(
        group: item.group,
        status: status(for: item),
        showsStatus: !isExpanded
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .tint(isReorderingGroups ? .clear : nil)
    .modifier(
      BottomSeparatorModifier(isHidden: isFinalRootItem && !isExpanded)
    )
  }

  /// Chats started without a project, behind one disclosure at the end of
  /// the by-project list.
  private var noProjectDisclosure: some View {
    let id = Self.noProjectItemID
    let isExpanded = expandedProjects.contains(id)
    let sessions = looseProjectSessions
    return DisclosureGroup(
      isExpanded: Binding(
        get: { expandedProjects.contains(id) },
        set: { setProject(id, isExpanded: $0) }
      )
    ) {
      ForEach(sessions) { session in
        chatRow(
          session,
          projectName: nil,
          hidesBottomSeparator: session.id == sessions.last?.id
        )
      }
      .onMove(perform: agentMoveAction(for: sessions))
    } label: {
      ProjectDisclosureLabel(
        title: "No project",
        symbolName: EntitySystemSymbol.projectList,
        status: sessions.map(status(for:)).min() ?? .idle,
        showsStatus: !isExpanded
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .modifier(BottomSeparatorModifier(isHidden: !isExpanded))
  }

  private func chatRow(
    _ session: ChatSession,
    projectName: String?,
    showsContext: Bool = true,
    hidesBottomSeparator: Bool? = nil
  ) -> some View {
    Button {
      openNotificationSession(session.id, serverId: session.serverId)
    } label: {
      SessionRow(
        session: session,
        projectName: projectName,
        harnessSymbol: harnessSymbol(for: session),
        status: status(for: session),
        showsContext: showsContext,
        machineName: machines.fleetMachineName(for: session.serverId)
      )
    }
    .buttonStyle(.plain)
    .swipeActions(edge: .trailing) {
      Button {
        _ = environment.archiveSessionAndWorkspaceIfEmpty(session)
        workspaceRevision += 1
      } label: {
        Label("Archive", systemImage: "archivebox")
      }
      .tint(.orange)
    }
    // Apply row traits outside the swipe wrapper so they reach the List's
    // actual cell rather than only the swipeable content hosted inside it.
    .modifier(BottomSeparatorModifier(isHidden: hidesBottomSeparator))
  }
}
