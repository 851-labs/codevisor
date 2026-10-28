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
  @State private var stepHandlerOwner = UUID()
  @State private var pendingImport: PendingSessionImport?
  @State var renamingWorkspace: Workspace?
  @State var workspaceRenameTitle = ""
  @State var drag: SidebarDrag?
  @State var groupDrag: SidebarGroupDrag?
  @State var holdsGroupToggles = false
  @State var revealRequest = SidebarRevealRequest()
  @ClientPreference(SidebarGrouping.preferenceKey, default: SidebarGrouping.flat) var grouping
  @ClientPreference(SidebarGrouping.collapsedPreferenceKey, default: []) var collapsedGroupIDs: [String]
  @ClientPreference(SidebarPreferenceKey.archivedExpanded, default: false) var archivedExpanded
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) var botsEnabled
  @ClientPreference(SidebarPreferenceKey.pinnedExpanded, default: true) var pinnedExpanded
  @ClientPreference(SidebarPreferenceKey.listExpanded, default: true) var listExpanded
  @State var archivedVisibleCount = sidebarArchivedPageSize
  @ClientPreference(SidebarPreferenceKey.pinnedWorkspaces, default: []) var pinnedWorkspaceIDs: [String]
  @ClientPreference(SidebarPreferenceKey.machineOrder, default: []) var machineOrder: [String]
  @ClientPreference(SidebarPreferenceKey.projectOrder, default: []) var projectOrder: [String]
  @State var dragGeometry = SidebarDragGeometryStore()

  var list: ProjectListModel { environment.projectList }
  var rowDetails: [SidebarRowDetail] { ClientPreferences.shared.sidebarRowDetails }
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
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 0) {
          newChatRows
          workspaceGroupList(workspaceGroups)
        }
      }
      .contextMenu { sidebarOptionsMenu }
      .onChange(of: selectedWorkspaceID, initial: true) { _, current in
        if let current, revealRequest.take(current) { proxy.scrollTo(current) }
      }
    }
    .scrollContentBackground(.hidden)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        SidebarSyncFooter(indicator: environment.navigationSyncIndicator)
        SidebarUpdateFooter(center: environment.updateCenter)
      }
    }
    .coordinateSpace(.named(Self.reorderSpace))
    .overlay(alignment: .topLeading) { reorderOverlay }
    .overlay(alignment: .topLeading) { groupReorderOverlay }
  }

  private var newChatRows: some View {
    VStack(alignment: .leading, spacing: 1) {
      if CodevisorAppVariant.isDevelopment && !AppPreview.isRunning {
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
    .padding(.horizontal, 10)
    .padding(.top, 8)
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
      get: { ClientPreferences.shared.isSidebarRowDetailShown(detail) },
      set: { ClientPreferences.shared.setSidebarRowDetail(detail, shown: $0) }
    )
  }

  private func workspaceGroupList(_ groups: [SidebarWorkspaceGroup]) -> some View {
    let headed = groups.filter { $0.id != SidebarWorkspaceGroup.pinnedID }.map(\.id)
    return workspaceRowList(sidebarRows)
      .padding(.horizontal, 10)
      .padding(.bottom, 8)
      .onChange(of: headed) { _, ids in endGroupDrag(ifMissingFrom: ids) }
  }

  static let groupIndent: CGFloat = 8

  private var vibrantContent: some View {
    let open = openSettings
    return SidebarVibrancyHost {
      sidebarContent
        .environment(environment)
        .environment(\.sidebarOpenSettings, SidebarOpenSettingsAction { open() })
    }
    .ignoresSafeArea(.container, edges: .top)
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
      .onDisappear {
        if publishesSceneActions {
          store?.clearWorkspaceStepHandler(owner: stepHandlerOwner)
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
      .modifier(
        SidebarModeSceneActions(
          key: \.sidebarActions, actions: publishesSceneActions && store != nil ? sceneActions : nil,
          store: publishesSceneActions ? store : nil, stepHandlerOwner: stepHandlerOwner, step: stepWorkspace)
      )
  }

  private var sceneActions: SidebarActions {
    SidebarActions(
      newChat: { selection = .newChat(nil) },
      newProject: { startAddProject() },
      stepWorkspace: { stepWorkspace($0) },
      archiveWorkspace: { archiveSelectedWorkspace() },
      activeWorkspace: { activeWorkspaceActions }
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
