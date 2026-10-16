import SwiftUI
import CodevisorCore
import CodevisorUI
import os

struct SidebarView: View {
  @Environment(AppEnvironment.self) var environment
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.openSettings) private var openSettings
  @Binding var selection: SidebarSelection?
  var store: SessionStore? = nil
  var publishesSceneActions = true

  @State private var showingAddProject = false
  @State private var pendingImport: PendingSessionImport?
  @State var renamingWorkspace: Workspace?
  @State var workspaceRenameTitle = ""
  @State var drag: SidebarDrag?
  @State var groupDrag: SidebarGroupDrag?
  @State var holdsGroupToggles = false
  @State var revealRequest = SidebarRevealRequest()
  @State var folds = SidebarFoldState()
  @ClientPreference(SidebarGrouping.preferenceKey, default: SidebarGrouping.flat) var grouping
  @ClientPreference(SidebarGrouping.collapsedPreferenceKey, default: []) var collapsedGroupIDs: [String]
  @ClientPreference(SidebarPreferenceKey.archivedExpanded, default: false) var archivedExpanded
  @ClientPreference(SidebarPreferenceKey.botsExpanded, default: true) var botsExpanded
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) var botsEnabled
  @State var botEditor: BotEditorTarget?
  @State var deletingBot: Bot?
  @ClientPreference(SidebarPreferenceKey.pinnedExpanded, default: true) var pinnedExpanded
  @ClientPreference(SidebarPreferenceKey.listExpanded, default: true) var listExpanded
  @State var archivedVisibleCount = sidebarArchivedPageSize
  @ClientPreference(SidebarPreferenceKey.pinnedWorkspaces, default: []) var pinnedWorkspaceIDs: [String]
  @ClientPreference(SidebarPreferenceKey.machineOrder, default: []) var machineOrder: [String]
  @ClientPreference(SidebarPreferenceKey.projectOrder, default: []) var projectOrder: [String]
  @ClientPreference(SidebarRowDetail.preferenceKey, default: SidebarRowDetail.defaults)
  var rowDetails: [SidebarRowDetail]
  @State var dragGeometry = SidebarDragGeometryStore()

  var list: ProjectListModel { environment.projectList }
  var isReordering: Bool { drag != nil || groupDrag != nil }

  var isNewChatSelected: Bool {
    switch selection {
    case .newChat, .none: true
    case .session, .workspace, .archivedWorkspace, .bot: false
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
        .onChange(of: selectedWorkspaceID) { previous, current in
          if let previous { release(previous) }
          if let current, revealRequest.take(current) { proxy.scrollTo(current) }
        }
        .onChange(of: selectedBotID) { previous, current in
          if let previous { release(previous) }
          if let current, revealRequest.take(current) { proxy.scrollTo(current) }
        }
      }
      .scrollContentBackground(.hidden)
      .scrollBounceBehavior(.basedOnSize)

      SidebarSyncFooter(indicator: environment.navigationSyncIndicator)
      SidebarUpdateFooter(center: environment.updateCenter)
    }
    .coordinateSpace(.named(Self.reorderSpace))
    .overlay(alignment: .topLeading) { reorderOverlay }
    .overlay(alignment: .topLeading) { groupReorderOverlay }
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
    if canCreateBots {
      Button("New Bot…", systemImage: "sparkles") { botEditor = .create }
    }
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
      botsSection
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
                guard allowsGroupToggle else { return }
                fold(group.id) { toggleGroup(group) }
              },
              onNewChat: heading.newChatTarget.map { target in { selection = .newChat(target) } }
            )
            .opacity(groupDrag?.groupID == group.id ? 0.4 : 1)
            .onGeometryChange(for: CGRect.self) { proxy in
              proxy.frame(in: .named(Self.reorderSpace))
            } action: { frame in
              dragGeometry.headings[group.id] = frame
            }
            .onDisappear { dragGeometry.headings[group.id] = nil }
            .simultaneousGesture(groupReorderGesture(for: group), including: reordersGroups ? .all : .subviews)
            .sidebarFoldingRow(listFolding, progress: progress, shows: listExpanded)
          }
          workspaceList(of: group)
            .padding(.leading, group.heading == nil ? 0 : Self.groupIndent * progress.shown)
            .sidebarFoldingRow(listFolding && !keepsSelection(group), progress: progress, shows: listExpanded)
        }
        .onGeometryChange(for: CGRect.self) { proxy in
          proxy.frame(in: .named(Self.reorderSpace))
        } action: { frame in
          dragGeometry.groups[group.id] = frame
        }
        .onDisappear { dragGeometry.groups[group.id] = nil }
      }
      archivedSection
    }
    .padding(.horizontal, 8)
    .padding(.bottom, 8)
    .animation(Motion.listReflow(reduceMotion: reduceMotion), value: groups.map(\.id))
    .onChange(of: rest.map(\.id)) { _, ids in endGroupDrag(ifMissingFrom: ids) }
  }

  static let groupIndent: CGFloat = 8
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

  func workspaceList(
    _ items: [WorkspaceSidebarItem], folding: Set<UUID>, releasing: Set<UUID>, shows: Bool
  ) -> some View {
    let routed = routedWorkspace
    let pinned = Set(pinnedWorkspaceIDs)
    let actions = rowActions
    return SidebarFoldingList(shows: shows, isReleasing: !releasing.isEmpty) { progress in
      ForEach(items) { item in
        SidebarWorkspaceSection(
          item: item, store: store, grouping: grouping, rowDetails: rowDetails,
          isSelected: routed?.serverId == item.serverId && routed?.id == item.id,
          isPinned: pinned.contains(item.id.uuidString), isReordering: isReordering, actions: actions
        )
        .equatable()
        .opacity(draggingID == item.id ? 0.4 : 1)
        .onGeometryChange(for: CGRect.self) { proxy in
          proxy.frame(in: .named(Self.reorderSpace))
        } action: { frame in
          recordWorkspaceFrame(frame, for: item.id)
        }
        .onDisappear { forgetWorkspaceGeometry(for: item.id) }
        .simultaneousGesture(reorderGesture(for: item.id))
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

  private var vibrantContent: some View {
    let open = openSettings
    return SidebarVibrancyHost {
      sidebarContent
        .environment(environment)
        .environment(\.sidebarOpenSettings, SidebarOpenSettingsAction { open() })
    }
  }

  private var sidebarInteractionView: some View {
    vibrantContent
      .contentShape(Rectangle())
      .sheet(isPresented: $showingAddProject) {
        NewProjectSheet(serverId: environment.defaultComposerServerId) { project in
          selection = .newChat(NewChatTarget(project))
          offerSessionImport(for: project)
        }
      }
      .modifier(SidebarBotsModifier(botEditor: $botEditor, deletingBot: $deletingBot, selection: $selection))
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

@MainActor
final class SidebarRevealRequest {
  var rowID: UUID?

  func take(_ id: UUID) -> Bool {
    defer { rowID = nil }
    return rowID == id
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
