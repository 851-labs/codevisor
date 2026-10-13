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
  @Environment(\.theme) private var theme
  @Environment(\.openSettings) private var openSettings
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
  @ClientPreference(SidebarGrouping.collapsedPreferenceKey, default: []) var collapsedGroupIDs: [String]
  /// The Archived section starts collapsed: the archive is somewhere you go
  /// looking, not something that should crowd the live list.
  @ClientPreference("sidebar.archivedExpanded", default: false) var archivedExpanded
  @ClientPreference("sidebar.pinnedExpanded", default: true) var pinnedExpanded
  /// The list's own heading collapses every group beneath it.
  @ClientPreference("sidebar.listExpanded", default: true) var listExpanded
  /// Not persisted: reopening the archive starts at the newest page.
  @State var archivedVisibleCount = archivedPageSize
  /// The archived workspace a click is asking to restore.
  @State var restoringWorkspace: Workspace?
  /// Workspaces pinned to the top of the sidebar, per device.
  @ClientPreference("sidebar.pinnedWorkspaces", default: []) var pinnedWorkspaceIDs: [String]
  @ClientPreference(SidebarRowDetail.preferenceKey, default: SidebarRowDetail.defaults)
  var rowDetails: [SidebarRowDetail]
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

      ScrollViewReader { proxy in
        ScrollView {
          workspaceGroupList(workspaceGroups)
        }
        .contextMenu { sidebarOptionsMenu }
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

  /// The list's heading, named for its top-level rows. Grouping and the
  /// row details live in the list's context menu.
  private var workspacesHeader: some View {
    SidebarSectionHeader(title: grouping.listTitle, isExpanded: listExpanded) {
      withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) { listExpanded.toggle() }
    }
  }

  /// The list's context menu: how rows are grouped, and which optional
  /// details each row shows.
  @ViewBuilder
  private var sidebarOptionsMenu: some View {
    Picker("Grouping", selection: $grouping) {
      ForEach(SidebarGrouping.allCases, id: \.self) { option in
        Text(option.title).tag(option)
      }
    }
    .pickerStyle(.menu)
    Menu("Show") {
      ForEach(SidebarRowDetail.allCases) { detail in
        Toggle(isOn: rowDetailBinding(detail)) {
          Label(detail.title, systemImage: detail.systemImage)
        }
      }
    }
  }

  private func rowDetailBinding(_ detail: SidebarRowDetail) -> Binding<Bool> {
    Binding(
      get: { rowDetails.contains(detail) },
      set: { isOn in
        rowDetails = SidebarRowDetail.allCases.filter { $0 == detail ? isOn : rowDetails.contains($0) }
      }
    )
  }

  /// The Pinned section (when anything is pinned), then the list's heading
  /// over each group's row and its workspace rows, which indent beneath it
  /// and hide while it is collapsed. A flat sidebar is one group with no row.
  /// Both headings scroll with the rows they introduce.
  private func workspaceGroupList(_ groups: [SidebarWorkspaceGroup]) -> some View {
    let pinned = groups.first { $0.id == SidebarWorkspaceGroup.pinnedID }
    let rest = groups.filter { $0.id != SidebarWorkspaceGroup.pinnedID }
    return VStack(alignment: .leading, spacing: 1) {
      if let pinned {
        SidebarSectionHeader(title: "Pinned", isExpanded: pinnedExpanded) {
          withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) { pinnedExpanded.toggle() }
        }
        if pinnedExpanded {
          workspaceList(pinned.items)
        }
      }
      workspacesHeader
      ForEach(listExpanded ? rest : []) { group in
        let isExpanded = isExpanded(group)
        if let heading = group.heading {
          SidebarGroupRow(
            title: heading.title,
            subtitle: heading.subtitle,
            systemImage: heading.systemImage,
            isExpanded: isExpanded,
            isReordering: isReordering,
            onToggle: {
              withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) { toggleGroup(group) }
            },
            onNewChat: heading.newChatTarget.map { target in { selection = .newChat(target) } }
          )
        }
        if isExpanded {
          workspaceList(group.items)
            .padding(.leading, group.heading == nil ? 0 : Self.groupIndent)
        }
      }
      archivedSection
    }
    .padding(.horizontal, 8)
    .padding(.bottom, 8)
    .animation(Motion.listReflow(reduceMotion: reduceMotion), value: groups.map(\.id))
  }

  /// How far a group's workspace rows sit in from the group's row.
  static let groupIndent: CGFloat = 8

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
          sidebar: self, item: item, selection: selection, grouping: grouping, rowDetails: rowDetails,
          draggingID: draggingID
        )
        .geometryGroup()
        .transition(.identity)
        .id(item.id)
      }
    }
    .animation(Motion.listReflow(reduceMotion: reduceMotion), value: items.map(\.id))
  }

  /// Under the system theme the split view's own sidebar material shows
  /// through, as in Mail or Finder: AppKit's sidebar material is what gives
  /// native sidebar text and headers their exact color (SwiftUI's regular
  /// material renders the same label colors lighter). Custom themes keep
  /// their tinted glass.
  @ViewBuilder
  private var sidebarBackground: some View {
    if theme.isSystem {
      vibrantContent
    } else {
      vibrantContent.themedSurface(.sidebar)
    }
  }

  /// The rows in their own hosting view, so they render with the sidebar's
  /// vibrancy (see `SidebarVibrancyHost`), carrying the environment they
  /// read across.
  private var vibrantContent: some View {
    let open = openSettings
    return SidebarVibrancyHost {
      sidebarContent
        .environment(environment)
        .environment(\.theme, theme)
        .environment(\.sidebarOpenSettings, SidebarOpenSettingsAction { open() })
    }
  }

  private var sidebarInteractionView: some View {
    sidebarBackground
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
      .alert(
        "Restore Workspace?",
        isPresented: Binding(get: { restoringWorkspace != nil }, set: { if !$0 { restoringWorkspace = nil } }),
        presenting: restoringWorkspace
      ) { workspace in
        Button("Restore") { environment.unarchiveWorkspace(workspace) }
        Button("Cancel", role: .cancel) {}
      } message: { workspace in
        Text("“\(SidebarWorkspaceRowLabel.title(for: workspace.name))” comes back with its tabs and worktree.")
      }
  }

  private var sidebarConfiguredView: some View {
    sidebarAlertsView
      // The docked sidebar answers ⇧⌘[ / ⇧⌘] and ⌥⌘↑ / ⌥⌘↓ from inside a
      // workspace (the drawer copy stays passive so there is exactly one
      // owner).
      .task(id: store.map(ObjectIdentifier.init)) {
        guard publishesSceneActions else { return }
        store?.workspaceStepHandler = { offset in stepWorkspace(offset) }
      }
      .onDisappear {
        if publishesSceneActions {
          store?.workspaceStepHandler = nil
        }
      }
      // PR badges: the docked sidebar keeps the window's answers fresh while
      // they show; the store re-asks a workspace only once its answer is stale.
      .task(id: pullRequestRefreshKey) {
        guard publishesSceneActions, pullRequestRefreshKey != nil else { return }
        while !Task.isCancelled {
          refreshPullRequests()
          try? await Task.sleep(for: .seconds(60))
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        if publishesSceneActions, pullRequestRefreshKey != nil { refreshPullRequests() }
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
