import SwiftUI
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import os

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

  @State private var showingAddProject = false
  @State private var pendingImport: PendingSessionImport?
  @State var renamingWorkspace: Workspace?
  @State var workspaceRenameTitle = ""
  @State var renamingTab: SidebarTabRenameRequest?
  @State var tabRenameTitle = ""
  @State var drag: SidebarDrag?
  @State var dragGeometry = SidebarDragGeometryStore()
  /// Collapsed by default: the archive is a place you go looking for
  /// something, not something that should crowd the live list.
  /// Page state is deliberately NOT persisted: reopening the archive should
  /// start at the newest page rather than restoring a deep scroll.
  /// The item a click is asking to restore, driving the confirmation alert.

  var list: ProjectListModel { environment.projectList }
  var isReordering: Bool { drag != nil }
  var itemTitleFont: Font { .body }

  var isNewChatSelected: Bool {
    switch selection {
    case .newChat, .none: true
    case .session, .workspace: false
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
        workspaceList(listedSidebarItems)
      }
      .scrollContentBackground(.hidden)
      .scrollBounceBehavior(.basedOnSize)

      SidebarSyncFooter(indicator: environment.navigationSyncIndicator)
      SidebarUpdateFooter(center: environment.updateCenter)
    }
    // Row frames, the drag copy, and the insertion line share this space,
    // so the overlay lines up with the rows it points between.
    .coordinateSpace(.named(Self.reorderSpace))
    .overlay(alignment: .topLeading) { reorderOverlay }
  }

  /// Iterates the precomputed list only; each section resolves its own
  /// workspace, so this body never reads a workspace's contents.
  private func workspaceList(_ items: [WorkspaceSidebarItem]) -> some View {
    // A plain VStack: lazy row materialization re-measures the
    // content mid-bounce, which reads as random overscroll snaps.
    VStack(alignment: .leading, spacing: 1) {
      // `.geometryGroup()` makes each section translate as one
      // rigid unit during reflows. Without it a row whose
      // content changes in the same transaction as its move
      // (the state change that reorders a chat also restyles
      // its leading icon) animates each subview's position
      // independently, which reads as shearing/jitter.
      ForEach(items) { item in
        SidebarWorkspaceSection(
          sidebar: self, item: item, selection: selection, draggingID: draggingID
        )
        .geometryGroup()
        .transition(.identity)
      }
    }
    .padding(.horizontal, 8)
    .padding(.bottom, 8)
    .animation(Motion.listReflow(reduceMotion: reduceMotion), value: items.map(\.id))
  }

  private var sidebarInteractionView: some View {
    sidebarContent
      .themedSurface(.sidebar)
      .contentShape(Rectangle())
      .sheet(isPresented: $showingAddProject) {
        NewProjectSheet(serverId: environment.defaultComposerServerId) { project in
          selection = .newChat(NewChatTarget(project))
          offerSessionImport(for: project)
        }
      }
  }

  private var sidebarAlertsView: some View {
    sidebarInteractionView
      .modifier(
        SidebarAlertsModifier(
          pendingImport: $pendingImport,
          renamingWorkspace: $renamingWorkspace,
          workspaceRenameTitle: $workspaceRenameTitle,
          onImport: { environment.importSessions($0.sessions, into: $0.project) },
          onRenameWorkspace: { renamed in
            environment.workspaceSync.renameWorkspace(
              renamed, client: environment.machines.client(for: renamed.serverId)
            )
          },
        )
      )
      .modifier(
        SidebarTabRenameAlert(
          request: $renamingTab,
          title: $tabRenameTitle,
          onRename: { renameTab($0, to: $1) }
        ))
  }

  private var sidebarConfiguredView: some View {
    sidebarAlertsView
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
            stepTab: { _ = stepSidebarTab($0) }
          )
          : nil
      )
  }

  /// The shared add-project sheet: a recent folder, any folder, or a clone.
  private func startAddProject() {
    showingAddProject = true
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
