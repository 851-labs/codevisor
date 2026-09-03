import SwiftUI
import UniformTypeIdentifiers
import CodevisorCore
import CodevisorTheming
import os
import CodevisorUI

/// How many archived chats one page reveals.
let archivedPageSize = 10

/// The sidebar: a New Chat action, an organization control, and fleet-wide
/// workspaces or agent sessions.
///
/// Built on `ScrollView` + `LazyVStack` (not `List`), because the sidebar-styled
/// `List` outline coordinator crashes on the current macOS SDK.
struct SidebarView: View {
  @Environment(AppEnvironment.self) var environment
  @Environment(\.theme) private var theme
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Binding var selection: SidebarSelection?
  var store: SessionStore? = nil
  var publishesSceneActions = true

  @State private var addProjectFlow = AddProjectFlow()
  @State private var showingRemoteMachine = false
  @State private var pendingImport: PendingSessionImport?
  // Seeded from the SQLite preference after the view mounts; written back
  // using the established newline-separated UUID representation.
  @State var expanded: Set<UUID> = []
  @State var expandedWorkspaces: Set<UUID> = []
  @State var renamingSession: ChatSession?
  @State var renameTitle = ""
  @State var renamingWorkspace: Workspace?
  @State var workspaceRenameTitle = ""
  @State var renamingNousTab: NousTabRenameRequest?
  @State var nousTabRenameTitle = ""
  /// Bumped after workspace mutations (backfill sweep, renames) so the
  /// non-observable repository is re-read.
  @State var workspaceRevision = 0
  @State var draggingProjectID: UUID?
  @State var draggingSessionID: UUID?
  @State var isPointerInsideSidebar = false
  @State var deferredProjectOrder = InteractionDeferredOrder<String>()
  @State var deferredSessionOrder = InteractionDeferredOrder<String>()
  @State var orderingCache = SidebarOrderingCache()
  /// Non-nil while a burst of automatic reorders is settling (the deferred
  /// orders are locked without the pointer being inside the sidebar).
  @State var reorderSettleHoldStart: Date?
  @State var reorderSettleTask: Task<Void, Never>?
  @ClientPreference("sidebar.organization", default: SidebarOrganization.compact.rawValue)
  private var organizationRaw
  @ClientPreference("sidebar.order", default: SidebarOrder.updated.rawValue)
  var orderRaw
  @ClientPreference("sidebar.manualProjectOrder", default: "")
  var manualProjectOrderRaw
  @ClientPreference("sidebar.manualSessionOrder", default: "")
  var manualSessionOrderRaw
  @ClientPreference("sidebar.expandedProjects", default: "")
  private var expandedProjectsRaw
  @ClientPreference("sidebar.expandedWorkspaces", default: "")
  private var expandedWorkspacesRaw
  @ClientPreference("sidebar.showEmptyProjects", default: false) var showEmptyProjects
  @ClientPreference("sidebar.showEmptyWorkspaces", default: false)
  var showEmptyWorkspaces
  /// Archived content is hidden until explicitly enabled from the sidebar
  /// filter menu, and the choice survives relaunches.
  @ClientPreference("sidebar.showArchived", default: false) private var showArchived
  /// Collapsed by default: the archive is a place you go looking for
  /// something, not something that should crowd the live list.
  @ClientPreference("sidebar.archivedExpanded", default: false) var archivedExpanded
  /// Page state is deliberately NOT persisted: reopening the archive should
  /// start at the newest page rather than restoring a deep scroll.
  @State var archivedVisibleCount = archivedPageSize
  @State var isLoadingMoreArchived = false
  /// The item a click is asking to restore, driving the confirmation alert.
  @State var restoreRequest: ArchivedRestoreRequest?

  var list: ProjectListModel { environment.projectList }
  var organization: SidebarOrganization { SidebarOrganization(rawValue: organizationRaw) ?? .compact }
  var order: SidebarOrder { SidebarOrder(rawValue: orderRaw) ?? .updated }
  var isReordering: Bool { draggingProjectID != nil || draggingSessionID != nil }
  var itemTitleFont: Font { .body }
  var hierarchyIndent: CGFloat { 8 }
  private var notificationColor: Color { theme.isSystem ? .blue : theme.accent }

  var body: some View {
    sidebarConfiguredView
  }

  private var sidebarContent: some View {
    VStack(spacing: 0) {
      // Development identity + New chat + the Projects header stay
      // pinned; only the project/chat list itself scrolls.
      VStack(alignment: .leading, spacing: 1) {
        if CodevisorAppVariant.isDevelopment {
          SidebarDevelopmentWorktreeRow()
        }

        SidebarActionRow(
          title: "New chat",
          systemImage: "square.and.pencil",
          isHoverEnabled: !isReordering
        ) {
          selection = .newChat(nil)
        }

        projectsHeader
      }
      .padding(.horizontal, 8)
      .padding(.top, 8)

      ScrollView {
        // A plain VStack: lazy row materialization re-measures the
        // content mid-bounce, which reads as random overscroll snaps.
        VStack(alignment: .leading, spacing: 1) {
          // `.geometryGroup()` makes each row translate as one
          // rigid unit during reflows. Without it a row whose
          // content changes in the same transaction as its move
          // (the state change that reorders a chat also restyles
          // its leading icon) animates each subview's position
          // independently, which reads as shearing/jitter.
          if organization == .byProject {
            ForEach(projectSectionProjects, id: \.sidebarFleetItemID) { project in
              projectFolder(project)
                .geometryGroup()
            }
            // Chats without a real project (scratch-backed
            // sessions) sit at the root as plain chat rows — a
            // single-use folder is not a project.
            ForEach(looseProjectSessions) { item in
              reorderableChronologicalSessionRow(item.session, project: item.project)
                .geometryGroup()
                .transition(.identity)
            }
          } else if organization.isWorkspaceList {
            ForEach(workspaceItems) { item in
              workspaceFolder(item)
                .geometryGroup()
                .transition(.identity)
            }
          } else {
            ForEach(chronologicalSessions) { item in
              reorderableChronologicalSessionRow(item.session, project: item.project)
                .geometryGroup()
                .transition(.identity)
            }
          }
          if organization == .byProject && projectSectionProjects.isEmpty
            && looseProjectSessions.isEmpty
          {
            Text("No projects yet")
              .font(.caption)
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 10)
              .padding(.vertical, 4)
              .transition(.identity)
          } else if organization.isWorkspaceList && workspaceItems.isEmpty {
            Text("No workspaces yet")
              .font(.caption)
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 10)
              .padding(.vertical, 4)
              .transition(.identity)
          } else if organization == .compact && chronologicalSessions.isEmpty {
            Text("No agents yet")
              .font(.caption)
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 10)
              .padding(.vertical, 4)
              .transition(.identity)
          }

          if showArchived {
            archivedSection
          }

        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .animation(Motion.listReflow(reduceMotion: reduceMotion), value: workspaceItems.map(\.id))
        .animation(Motion.listReflow(reduceMotion: reduceMotion), value: nousTabIDs)
        .animation(Motion.listReflow(reduceMotion: reduceMotion), value: chronologicalSessions.map(\.id))
        .animation(
          Motion.listReflow(reduceMotion: reduceMotion),
          value: projectSectionProjects.map(\.sidebarFleetItemID)
        )
        .animation(Motion.listReflow(reduceMotion: reduceMotion), value: expanded)
        .animation(Motion.listReflow(reduceMotion: reduceMotion), value: expandedWorkspaces)
        // Same reflow the project/workspace disclosures use, so the
        // archive opens and closes with the rest of the sidebar.
        .animation(Motion.listReflow(reduceMotion: reduceMotion), value: showArchived)
        .animation(Motion.listReflow(reduceMotion: reduceMotion), value: archivedExpanded)
        .animation(Motion.listReflow(reduceMotion: reduceMotion), value: archivedVisibleCount)
      }
      .scrollContentBackground(.hidden)
      .scrollBounceBehavior(.basedOnSize)
      .contextMenu {
        sidebarFilterMenuContent
      }

      SidebarUpdateFooter(center: environment.updateCenter)
    }
  }

  private var sidebarInteractionView: some View {
    sidebarContent
      .themedSurface(.sidebar)
      .hoverTracking($isPointerInsideSidebar, respectsSuspension: false)
      .onChange(of: isPointerInsideSidebar) { _, isInside in
        setAutomaticOrderDeferred(isInside)
      }
      .onDisappear {
        releaseDeferredOrder(animated: false)
      }
      .addProjectFlow(addProjectFlow) { project in
        expanded.insert(project.id)
        selection = .newChat(NewChatTarget(project))
        offerSessionImport(for: project)
      }
  }

  private var sidebarAlertsView: some View {
    sidebarInteractionView
      .modifier(
        SidebarAlertsModifier(
          pendingImport: $pendingImport,
          renamingSession: $renamingSession,
          renameTitle: $renameTitle,
          renamingWorkspace: $renamingWorkspace,
          workspaceRenameTitle: $workspaceRenameTitle,
          restoreRequest: $restoreRequest,
          onImport: { environment.importSessions($0.sessions, into: $0.project) },
          onRenameSession: { list.renameSession($0, to: $1) },
          onRenameWorkspace: { renamed in
            environment.workspaces.save(renamed)
            workspaceRevision += 1
          },
          onPerformRestore: { performRestore($0) }
        )
      )
      .modifier(
        NousTabRenameAlert(
          request: $renamingNousTab,
          title: $nousTabRenameTitle,
          onRename: { renameNousTab($0, to: $1) }
        ))
  }

  private var sidebarChangeObserversView: some View {
    sidebarAlertsView
      // Collapsing resets paging so reopening starts at the newest page
      // instead of restoring a deep scroll the user has forgotten about.
      .onChange(of: archivedExpanded) { _, isExpanded in
        if !isExpanded {
          archivedVisibleCount = archivedPageSize
          isLoadingMoreArchived = false
        }
      }
      // Entering a workspace-based mode (or sessions changing while in it)
      // sweeps the visible chats so every one has an owning workspace.
      .onChange(of: organizationRaw, initial: true) { _, _ in
        backfillWorkspaces()
        revealRoutedNousWorkspace()
      }
      // A tab added to a workspace (⌘T, a New Tab conversion elsewhere)
      // shows up as a row; make sure its folder is open to receive it.
      .onChange(of: nousTabIDs) { oldIDs, newIDs in
        revealNousTabWorkspaces(added: Set(newIDs).subtracting(oldIDs))
      }
      .onChange(of: chronologicalSessions.map(\.orderingID)) { oldIDs, newIDs in
        deferredSessionOrder.incorporate(newIDs)
        backfillWorkspaces()
        let addedOrderIDs = Set(newIDs).subtracting(Set(oldIDs))
        let addedSessionIDs = chronologicalSessions.compactMap { item in
          addedOrderIDs.contains(item.orderingID) ? item.session.id : nil
        }
        revealNewChatWorkspaces(Set(addedSessionIDs))
      }
      .onChange(of: visibleProjects.map(\.sidebarFleetOrderID)) { _, newIDs in
        deferredProjectOrder.incorporate(newIDs)
      }
      // Bursty automatic reorders (several agents changing state at once)
      // are jarring, and each interrupts the previous reflow animation
      // mid-flight, which reads as jitter. Watching the unheld sort lets a
      // burst land as one clean reflow after it settles.
      .onChange(of: desiredAutomaticOrderIDs) { _, _ in
        scheduleReorderSettleHold()
      }
  }

  private var sidebarSheetsView: some View {
    sidebarChangeObserversView
      .modifier(
        SidebarSheetsModifier(
          showingRemoteMachine: $showingRemoteMachine,
          onAddRemoteMachine: { host, name, token, syncConfig in
            do {
              let machine = try await environment.machines.addRemoteValidating(
                host: host, name: name, token: token, syncConfig: syncConfig)
              environment.composerDefaults.rememberNewWorkspaceServer(
                serverId: machine.id
              )
              selection = .newChat(nil)
              return nil
            } catch {
              Log.machines.error(
                "Adding remote machine failed: \(String(describing: error), privacy: .public)")
              if case CodevisorServerClientError.httpStatus(401, _) = error {
                return "That connection token was rejected by the machine."
              }
              return serverErrorMessage(error)
            }
          }
        ))
  }

  private var sidebarConfiguredView: some View {
    sidebarSheetsView
      .onAppear(perform: restoreExpandedState)
      // The docked sidebar answers ⇧⌘[ / ⇧⌘] in Nous mode (the drawer copy
      // stays passive so there is exactly one owner of the step).
      .task(id: store.map(ObjectIdentifier.init)) {
        guard publishesSceneActions else { return }
        store?.nousStepHandler = { offset in stepNous(offset) }
      }
      .onDisappear {
        if publishesSceneActions { store?.nousStepHandler = nil }
      }
      .onChange(of: expanded) { _, newValue in
        expandedProjectsRaw = newValue.map(\.uuidString).sorted().joined(separator: "\n")
      }
      .onChange(of: expandedWorkspaces) { _, newValue in
        expandedWorkspacesRaw = newValue.map(\.uuidString).sorted().joined(separator: "\n")
      }
      .focusedSceneValue(
        \.sidebarActions,
        publishesSceneActions
          ? SidebarActions(
            newChat: { selection = .newChat(nil) },
            newProject: { startAddProject() },
            addRemoteMachine: { showingRemoteMachine = true }
          )
          : nil
      )
  }

  /// One shared flow: pick a folder on the machine or clone a repository.
  private func startAddProject() {
    addProjectFlow.begin()
  }

  private func restoreExpandedState() {
    expanded = persistedIDs(from: expandedProjectsRaw)
    expandedWorkspaces = persistedIDs(from: expandedWorkspacesRaw)
  }

  private func persistedIDs(from rawValue: String) -> Set<UUID> {
    let ids: [UUID] =
      rawValue
      .split(separator: "\n")
      .compactMap { UUID(uuidString: String($0)) }
    return Set(ids)
  }

  /// After a project is added, look for existing harness sessions in its
  /// folder and — only when some are found — offer to import them.
  private func offerSessionImport(for project: Project) {
    Task {
      let importable = await environment.findImportableSessions(
        for: project.folderURL,
        serverId: project.serverId
      )
      guard !importable.isEmpty else { return }
      pendingImport = PendingSessionImport(project: project, sessions: importable)
    }
  }

  // MARK: - Header rows

  private var projectsHeader: some View {
    HStack {
      Text(
        {
          switch organization {
          case .byWorkspace, .nous: "Workspaces"
          case .compact: "Agents"
          case .byProject: "Projects"
          }
        }()
      )
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
      Spacer()
      Menu {
        sidebarFilterMenuContent
      } label: {
        Image(systemName: "line.3.horizontal.decrease")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .help("Organize and filter sidebar")
      .accessibilityLabel("Organize and filter sidebar")
    }
    .padding(.horizontal, 10)
    .padding(.top, 12)
    .padding(.bottom, 4)
  }

  /// Shared by the filter button and the empty-space sidebar context menu so
  /// both entry points always expose the same organization and filter state.
  private var sidebarFilterMenuContent: some View {
    SidebarFilterMenu(
      organization: organization,
      order: order,
      showEmptyProjects: $showEmptyProjects,
      showEmptyWorkspaces: $showEmptyWorkspaces,
      showArchived: $showArchived,
      onSetOrganization: { organizationRaw = $0.rawValue },
      onSetOrder: { setOrder($0) },
      onResetManualOrder: { resetManualOrder() }
    )
  }

}

#Preview {
  @Previewable @State var selection: SidebarSelection?
  return NavigationSplitView {
    SidebarView(selection: $selection)
      .environment(AppEnvironment.preview())
  } detail: {
    Text("Detail")
  }
  .frame(width: 900, height: 600)
}
