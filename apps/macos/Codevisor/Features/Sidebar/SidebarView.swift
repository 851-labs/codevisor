import SwiftUI
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import os

/// The sidebar: a New Chat action and one row per fleet-wide workspace,
/// optionally grouped by project or machine.
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
  @State var drag: SidebarDrag?
  /// The row a keyboard step landed on, scrolled into view.
  @State var revealedWorkspaceID: UUID?
  @ClientPreference(SidebarGrouping.preferenceKey, default: SidebarGrouping.flat) var grouping
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
      // Development identity and New chat stay pinned; workspace rows
      // scroll.
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

      workspacesHeader
        .padding(.horizontal, 8)

      ScrollViewReader { proxy in
        ScrollView {
          workspaceGroupList(workspaceGroups)
        }
        .contextMenu { groupingPicker }
        .onChange(of: revealedWorkspaceID) { _, id in
          guard let id else { return }
          withAnimation(Motion.quick(reduceMotion: reduceMotion)) { proxy.scrollTo(id) }
          revealedWorkspaceID = nil
        }
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

  /// The Workspaces heading, carrying the grouping menu.
  private var workspacesHeader: some View {
    SidebarSectionHeader(title: "Workspaces") {
      Menu {
        groupingPicker
      } label: {
        Image(systemName: "line.3.horizontal.decrease")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .fixedSize()
      .help("Group sidebar")
      .accessibilityLabel("Group sidebar")
    }
  }

  /// Shared by the header's menu and the list's context menu.
  private var groupingPicker: some View {
    Picker("Group By", selection: $grouping) {
      ForEach(SidebarGrouping.allCases, id: \.self) { option in
        Text(option.title).tag(option)
      }
    }
    .pickerStyle(.inline)
  }

  /// Each group's heading over its rows. A flat sidebar is one untitled
  /// group.
  private func workspaceGroupList(_ groups: [SidebarWorkspaceGroup]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(groups) { group in
        if let title = group.title {
          SidebarSectionHeader(title: title, subtitle: group.subtitle)
        }
        workspaceList(group.items)
      }
    }
    .padding(.horizontal, 8)
    .padding(.bottom, 8)
    .animation(Motion.listReflow(reduceMotion: reduceMotion), value: groups.map(\.id))
  }

  /// Iterates the precomputed list only; each section resolves its own
  /// workspace, so this body never reads a workspace's contents.
  private func workspaceList(_ items: [WorkspaceSidebarItem]) -> some View {
    // A plain VStack: lazy row materialization re-measures the
    // content mid-bounce, which reads as random overscroll snaps.
    VStack(alignment: .leading, spacing: 1) {
      // `.geometryGroup()` makes each row translate as one
      // rigid unit during reflows. Without it a row whose
      // content changes in the same transaction as its move
      // (the state change that reorders a workspace also
      // restyles its leading icon) animates each subview's
      // position independently, which reads as shearing/jitter.
      ForEach(items) { item in
        SidebarWorkspaceSection(
          sidebar: self, item: item, selection: selection, grouping: grouping, draggingID: draggingID
        )
        .geometryGroup()
        .transition(.identity)
        .id(item.id)
      }
    }
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
  }

  private var sidebarConfiguredView: some View {
    sidebarAlertsView
      // The docked sidebar answers ⌥⌘↑ / ⌥⌘↓ from inside a workspace (the
      // drawer copy stays passive so there is exactly one owner).
      .task(id: store.map(ObjectIdentifier.init)) {
        guard publishesSceneActions else { return }
        store?.workspaceStepHandler = { offset in stepWorkspace(offset) }
      }
      .onDisappear {
        if publishesSceneActions { store?.workspaceStepHandler = nil }
      }
      .focusedSceneValue(
        \.sidebarActions,
        // Navigation captures the store; wait until it is available before
        // publishing the closures retained by the scene's focused value.
        publishesSceneActions && store != nil
          ? SidebarActions(
            newChat: { selection = .newChat(nil) },
            newProject: { startAddProject() },
            stepWorkspace: { stepWorkspace($0) }
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
