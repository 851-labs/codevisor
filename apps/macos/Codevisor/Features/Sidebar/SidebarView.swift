import SwiftUI
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import os

/// How many archived chats one page reveals.
let archivedPageSize = 10

/// The sidebar: a New Chat action and fleet-wide workspaces with their tabs.
///
/// Built on `ScrollView` + `VStack` (not `List`), because the sidebar-styled
/// `List` outline coordinator crashes on the current macOS SDK.
struct SidebarView: View {
  @Environment(AppEnvironment.self) var environment
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Binding var selection: SidebarSelection?
  var store: SessionStore? = nil
  var publishesSceneActions = true

  @State private var addProjectFlow = AddProjectFlow()
  @State private var showingRemoteMachine = false
  @State private var pendingImport: PendingSessionImport?
  @State var renamingWorkspace: Workspace?
  @State var workspaceRenameTitle = ""
  @State var renamingTab: SidebarTabRenameRequest?
  @State var tabRenameTitle = ""
  /// Bumped after workspace mutations (backfill sweep, renames) so the
  /// non-observable repository is re-read.
  @State var workspaceRevision = 0
  @State var draggingWorkspaceID: UUID?
  @ClientPreference("sidebar.manualWorkspaceOrder", default: "")
  var manualWorkspaceOrderRaw
  @ClientPreference("sidebar.showArchived", default: false) var showArchived
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
  var isReordering: Bool { draggingWorkspaceID != nil }
  var itemTitleFont: Font { .body }

  var isNewChatSelected: Bool {
    switch selection {
    case .newChat, .none: true
    case .session: false
    }
  }

  var body: some View {
    sidebarConfiguredView
  }

  private var sidebarContent: some View {
    VStack(spacing: 0) {
      // Development identity and New chat stay pinned; workspace
      // sections scroll together with their tabs.
      VStack(alignment: .leading, spacing: 1) {
        if CodevisorAppVariant.isDevelopment {
          SidebarDevelopmentWorktreeRow()
        }

        SidebarActionRow(
          title: "New chat",
          systemImage: "square.and.pencil",
          isSelected: isNewChatSelected,
          isHoverEnabled: !isReordering
        ) {
          selection = .newChat(nil)
        }
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
          ForEach(workspaceItems) { item in
            workspaceSection(item)
              .geometryGroup()
              .transition(.identity)
          }

          if showArchived {
            archivedSection
          }

        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .animation(Motion.listReflow(reduceMotion: reduceMotion), value: workspaceItems.map(\.id))
        .animation(Motion.listReflow(reduceMotion: reduceMotion), value: workspaceTabRowIDs)
        .animation(Motion.listReflow(reduceMotion: reduceMotion), value: archivedExpanded)
        .animation(Motion.listReflow(reduceMotion: reduceMotion), value: archivedVisibleCount)
      }
      .scrollContentBackground(.hidden)
      .scrollBounceBehavior(.basedOnSize)

      SidebarUpdateFooter(center: environment.updateCenter)
    }
  }

  private var sidebarInteractionView: some View {
    sidebarContent
      .themedSurface(.sidebar)
      .contentShape(Rectangle())
      .contextMenu {
        Toggle("Show Archived", isOn: $showArchived)
      }
      .addProjectFlow(addProjectFlow) { project in
        selection = .newChat(NewChatTarget(project))
        offerSessionImport(for: project)
      }
  }

  private var sidebarAlertsView: some View {
    sidebarInteractionView
      .modifier(
        SidebarAlertsModifier(
          pendingImport: $pendingImport,
          renamingWorkspace: $renamingWorkspace,
          workspaceRenameTitle: $workspaceRenameTitle,
          restoreRequest: $restoreRequest,
          onImport: { environment.importSessions($0.sessions, into: $0.project) },
          onRenameWorkspace: { renamed in
            environment.workspaceSync.renameWorkspace(
              renamed, client: environment.machines.client(for: renamed.serverId)
            )
            workspaceRevision += 1
          },
          onPerformRestore: { performRestore($0) }
        )
      )
      .modifier(
        SidebarTabRenameAlert(
          request: $renamingTab,
          title: $tabRenameTitle,
          onRename: { renameTab($0, to: $1) }
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
      .onChange(of: Set(activeSessionItems.map(\.id))) { _, _ in
        ensureSessionWorkspaces()
      }
      // Persist the initial order and incorporate new workspaces once, so
      // adding or closing chats never changes an existing workspace's rank.
      .onChange(of: workspaceItems.map(\.workspace.id), initial: true) { _, ids in
        rememberWorkspaceOrder(ids)
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
      .onAppear(perform: ensureSessionWorkspaces)
      // The docked sidebar answers ⇧⌘[ / ⇧⌘] (the drawer copy
      // stays passive so there is exactly one owner of the step).
      .task(id: store.map(ObjectIdentifier.init)) {
        guard publishesSceneActions else { return }
        store?.sidebarTabStepHandler = { offset in stepSidebarTab(offset) }
      }
      .onDisappear {
        if publishesSceneActions { store?.sidebarTabStepHandler = nil }
      }
      .focusedSceneValue(
        \.sidebarActions,
        // Navigation captures the store; wait until it is available before
        // publishing the closures retained by the scene's focused value.
        publishesSceneActions && store != nil
          ? SidebarActions(
            newChat: { selection = .newChat(nil) },
            newProject: { startAddProject() },
            addRemoteMachine: { showingRemoteMachine = true },
            stepTab: { _ = stepSidebarTab($0) }
          )
          : nil
      )
  }

  /// One shared flow: pick a folder on the machine or clone a repository.
  private func startAddProject() {
    addProjectFlow.begin()
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
