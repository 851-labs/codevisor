import SwiftUI
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import os

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
  @State var revealedWorkspaceID: UUID?
  @State var folds = SidebarFoldState()
  @ClientPreference(SidebarGrouping.preferenceKey, default: SidebarGrouping.flat) var grouping
  @ClientPreference(SidebarGrouping.collapsedPreferenceKey, default: []) var collapsedGroupIDs: [String]
  @ClientPreference("sidebar.archivedExpanded", default: false) var archivedExpanded
  @ClientPreference("sidebar.pinnedExpanded", default: true) var pinnedExpanded
  @ClientPreference("sidebar.listExpanded", default: true) var listExpanded
  @State var archivedVisibleCount = archivedPageSize
  @ClientPreference(Self.pinnedWorkspacesKey, default: []) var pinnedWorkspaceIDs: [String]
  @ClientPreference(SidebarRowDetail.preferenceKey, default: SidebarRowDetail.defaults)
  var rowDetails: [SidebarRowDetail]
  @State var dragGeometry = SidebarDragGeometryStore()

  var list: ProjectListModel { environment.projectList }
  var isReordering: Bool { drag != nil }

  var isNewChatSelected: Bool {
    switch selection {
    case .newChat, .none: true
    case .session, .workspace, .archivedWorkspace: false
    }
  }

  var body: some View {
    sidebarConfiguredView
  }

  private var sidebarContent: some View {
    VStack(spacing: 0) {
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
          proxy.scrollTo(id)
          revealedWorkspaceID = nil
        }
        .onChange(of: selectedWorkspaceID) { previous, _ in
          if let previous { release(previous) }
        }
      }
      .scrollContentBackground(.hidden)
      .scrollBounceBehavior(.basedOnSize)

      SidebarSyncFooter(indicator: environment.navigationSyncIndicator)
      SidebarUpdateFooter(center: environment.updateCenter)
    }
    .coordinateSpace(.named(Self.reorderSpace))
    .overlay(alignment: .topLeading) { reorderOverlay }
  }

  private var workspacesHeader: some View {
    SidebarSectionHeader(title: grouping.listTitle, isExpanded: listExpanded) {
      fold(Self.listSection) { listExpanded.toggle() }
    }
  }

  @ViewBuilder
  private var sidebarOptionsMenu: some View {
    Picker(selection: $grouping) {
      ForEach(SidebarGrouping.allCases, id: \.self) { option in
        Text(option.title).tag(option)
      }
    } label: {
      Label("Grouping", systemImage: "rectangle.3.group")
        .labelStyle(.titleAndIcon)
    }
    .pickerStyle(.menu)
    Menu {
      ForEach(SidebarRowDetail.trailingDetails) { detail in
        rowDetailToggle(detail)
      }
      Divider()
      ForEach(SidebarRowDetail.subtitleDetails) { detail in
        rowDetailToggle(detail)
      }
    } label: {
      Label("Properties", systemImage: "list.bullet")
        .labelStyle(.titleAndIcon)
    }
  }

  private func rowDetailToggle(_ detail: SidebarRowDetail) -> some View {
    Toggle(isOn: rowDetailBinding(detail)) {
      Label(detail.title, systemImage: detail.systemImage)
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

  private func workspaceGroupList(_ groups: [SidebarWorkspaceGroup]) -> some View {
    let pinned = groups.first { $0.id == SidebarWorkspaceGroup.pinnedID }
    let rest = groups.filter { $0.id != SidebarWorkspaceGroup.pinnedID }
    let listFolding = folds.isFolding(Self.listSection)
    return SidebarStack(spacing: 1) {
      if let pinned {
        SidebarSectionHeader(title: "Pinned", isExpanded: pinnedExpanded) {
          fold(pinned.id) { pinnedExpanded.toggle() }
        }
        workspaceList(of: pinned)
      }
      workspacesHeader
      ForEach(rest) { group in
        SidebarFoldingList(shows: listExpanded) { progress in
          if let heading = group.heading, listExpanded || listFolding {
            SidebarGroupRow(
              title: heading.title,
              systemImage: heading.systemImage,
              isExpanded: isExpanded(group),
              isReordering: isReordering,
              onToggle: {
                fold(group.id) { toggleGroup(group) }
              },
              onNewChat: heading.newChatTarget.map { target in { selection = .newChat(target) } }
            )
            .sidebarFoldingRow(listFolding, progress: progress, shows: listExpanded)
          }
          workspaceList(of: group)
            .padding(.leading, group.heading == nil ? 0 : Self.groupIndent * progress.shown)
            .sidebarFoldingRow(listFolding && !keepsSelection(group), progress: progress, shows: listExpanded)
        }
      }
      archivedSection
    }
    .padding(.horizontal, 8)
    .padding(.bottom, 8)
    .animation(Motion.listReflow(reduceMotion: reduceMotion), value: groups.map(\.id))
  }

  static let groupIndent: CGFloat = 8
  static let pinnedWorkspacesKey = "sidebar.pinnedWorkspaces"
  static let listSection = "list"

  private func keepsSelection(_ group: SidebarWorkspaceGroup) -> Bool {
    group.items.contains { $0.id == selectedWorkspaceID }
  }

  private func isFolding(_ group: SidebarWorkspaceGroup) -> Bool {
    folds.isFolding(group.id)
      || (group.id != SidebarWorkspaceGroup.pinnedID && folds.isFolding(Self.listSection))
  }

  func fold(_ section: String, _ change: () -> Void) {
    let folds = folds
    let generation = folds.begin(section)
    change()
    Task {
      try? await Task.sleep(for: .seconds(Motion.listReflowDuration * 2))
      folds.end(section, generation: generation)
    }
  }

  private func workspaceList(of group: SidebarWorkspaceGroup) -> some View {
    let visible = visibleItems(of: group)
    guard isFolding(group) else {
      let rows = withReleasedRows(visible, from: group.items)
      return workspaceList(rows.items, folding: [], releasing: rows.releasing, shows: isShowing(group))
    }
    let kept = group.items.filter { $0.id == selectedWorkspaceID }
    let shown = folds.isFolding(group.id) || isExpanded(group) ? group.items : visible
    let folding = Set(shown.map(\.id)).subtracting(kept.map(\.id))
    return workspaceList(shown, folding: folding, releasing: [], shows: isShowing(group))
  }

  func withReleasedRows(
    _ visible: [WorkspaceSidebarItem], from items: [WorkspaceSidebarItem]
  ) -> (items: [WorkspaceSidebarItem], releasing: Set<UUID>) {
    let visibleIDs = Set(visible.map(\.id))
    let releasing = Set(items.lazy.map(\.id).filter { !visibleIDs.contains($0) && folds.isReleasing($0) })
    guard !releasing.isEmpty else { return (visible, []) }
    return (items.filter { visibleIDs.contains($0.id) || releasing.contains($0.id) }, releasing)
  }

  func release(_ id: UUID) {
    let folds = folds
    let generation = folds.release(id)
    Task {
      try? await Task.sleep(for: .seconds(Motion.listReflowDuration * 2))
      folds.endRelease(id, generation: generation)
    }
  }

  private func workspaceList(
    _ items: [WorkspaceSidebarItem], folding: Set<UUID>, releasing: Set<UUID>, shows: Bool
  ) -> some View {
    SidebarFoldingList(shows: shows, isReleasing: !releasing.isEmpty) { progress in
      ForEach(items) { item in
        SidebarWorkspaceSection(
          sidebar: self, item: item, selection: selection, grouping: grouping, rowDetails: rowDetails,
          draggingID: draggingID
        )
        .geometryGroup()
        .sidebarFoldingRow(
          releasing.contains(item.id) ? .releasing : folding.contains(item.id) ? .folding : .kept,
          progress: progress, shows: shows
        )
        .transition(.identity)
        .id(item.id)
      }
    }
    .animation(folding.isEmpty ? Motion.listReflow(reduceMotion: reduceMotion) : nil, value: items.map(\.id))
  }

  @ViewBuilder
  private var sidebarBackground: some View {
    if theme.isSystem {
      vibrantContent
    } else {
      vibrantContent.themedSurface(.sidebar)
    }
  }

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
  }

  private var sidebarConfiguredView: some View {
    sidebarAlertsView
      .task(id: store.map(ObjectIdentifier.init)) {
        guard publishesSceneActions else { return }
        store?.workspaceStepHandler = { offset in stepWorkspace(offset) }
      }
      .onDisappear {
        if publishesSceneActions {
          store?.workspaceStepHandler = nil
        }
      }
      .task(id: gitLookupRefreshKey) {
        guard publishesSceneActions, gitLookupRefreshKey != nil else { return }
        while !Task.isCancelled {
          refreshGitLookups()
          try? await Task.sleep(for: .seconds(60))
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        if publishesSceneActions, gitLookupRefreshKey != nil { refreshGitLookups() }
      }
      .focusedSceneValue(
        \.sidebarActions,
        publishesSceneActions && store != nil
          ? SidebarActions(
            newChat: { selection = .newChat(nil) },
            newProject: { startAddProject() },
            stepWorkspace: { stepWorkspace($0) },
            archiveWorkspace: { archiveSelectedWorkspace() }
          )
          : nil
      )
  }

  private func startAddProject() {
    showingAddProject = true
  }

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
