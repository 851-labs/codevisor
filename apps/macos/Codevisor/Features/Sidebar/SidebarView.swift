import SwiftUI
import CodevisorCore
import CodevisorUI
import os

struct SidebarView: View {
  @Environment(AppEnvironment.self) var environment
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.isActiveSidebarMode) private var isActiveSidebarMode
  @SidebarSelectionRef var selection: SidebarSelection?
  var store: SessionStore? = nil
  var publishesSceneActions = true

  @State private var showingAddProject = false
  @State private var stepHandlerOwner = UUID()
  @State private var pendingImport: PendingSessionImport?
  @State var renamingWorkspace: Workspace?
  @State var sectionPrompt: SectionPrompt?
  @State var reorder = SidebarReorder<SidebarRowID>()
  @State var tabDrag: SidebarTabDrag?
  @State var revealRequest = SidebarRevealRequest()
  @State var selectionModel = SidebarSelectionModel()
  @State var shownRows = SidebarShownRows()
  @ClientPreference(SidebarGrouping.collapsedPreferenceKey, default: []) var collapsedGroupIDs: [String]
  @ClientPreference(SidebarPreferenceKey.archivedExpanded, default: false) var archivedExpanded
  @ClientPreference(SidebarPreferenceKey.pinnedExpanded, default: true) var pinnedExpanded
  @ClientPreference(SidebarPreferenceKey.listExpanded, default: true) var listExpanded
  @State var archivedVisibleCount = sidebarArchivedPageSize
  @ClientPreference(SidebarPreferenceKey.pinnedWorkspaces, default: []) var pinnedWorkspaceIDs: [String]
  @ClientPreference(SidebarPreferenceKey.machineOrder, default: []) var machineOrder: [String]
  @ClientPreference(SidebarPreferenceKey.projectOrder, default: []) var projectOrder: [String]
  @State var dragGeometry = SidebarDragGeometryStore()

  var list: ProjectListModel { environment.projectList }
  var groupingChoice: SidebarGroupingChoice { SidebarGroupingChoice(environment: environment) }
  var grouping: SidebarGrouping { groupingChoice.effective }
  var rowDetails: [SidebarRowDetail] { ClientPreferences.shared.sidebarRowDetails }
  var isReordering: Bool { reorder.lifted != nil || tabDrag != nil }

  var body: some View {
    sidebarConfiguredView
  }

  private var sidebarContent: some View {
    let rows = sidebarRows
    let rowIDs = shownRows.show(rows)
    return ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 0) {
          newChatRows
          if !rows.isEmpty {
            workspaceGroupList(workspaceGroups, rows: rows)
          }
        }
        .padding(.top, 8)
      }
      .overlay {
        if rows.isEmpty { emptyPlaceholder }
      }
      .contextMenu { sidebarOptionsMenu }
      .onScrollGeometryChange(for: ClosedRange<CGFloat>.self) { geometry in
        geometry.contentInsets
          .top...max(
            geometry.contentInsets.top, geometry.containerSize.height - geometry.contentInsets.bottom)
      } action: { _, visible in
        dragGeometry.visibleRows = visible
      }
      .background(
        SidebarSelectionSyncView(
          target: { selectionTarget }, rowIDs: rowIDs, model: selectionModel,
          takeScrollRequest: { revealRequest.take($0) },
          scroll: { proxy.scrollTo($0) })
      )
    }
    .scrollContentBackground(.hidden)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        SidebarSyncFooter(indicator: environment.navigationSyncIndicator)
        SidebarUpdateFooter(center: environment.updateCenter)
      }
    }
    .coordinateSpace(SidebarReorderSpace.coordinateSpace)
    .overlay(alignment: .topLeading) { SidebarReorderOverlay(reorder: reorder) { reorderGhost(for: $0) } }
    .overlay(alignment: .topLeading) { tabReorderOverlay }
  }

  @ViewBuilder
  private var sidebarOptionsMenu: some View {
    Button {
      sectionPrompt = .create(moving: nil)
    } label: {
      Label("New Section…", systemImage: "folder.badge.plus")
        .labelStyle(.titleAndIcon)
    }
    Divider()
    Picker(selection: groupingChoice.selection) {
      ForEach(SidebarGrouping.allCases, id: \.self) { option in
        Label {
          Text(option.title)
        } icon: {
          option.icon
        }
        .labelStyle(.titleAndIcon)
        .tag(option)
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
      Label {
        Text(detail.title)
      } icon: {
        detail.icon
      }
      .labelStyle(.titleAndIcon)
    }
  }

  private func rowDetailBinding(_ detail: SidebarRowDetail) -> Binding<Bool> {
    Binding(
      get: { ClientPreferences.shared.isSidebarRowDetailShown(detail) },
      set: { ClientPreferences.shared.setSidebarRowDetail(detail, shown: $0) }
    )
  }

  private var newChatRows: some View {
    VStack(alignment: .leading, spacing: 1) {
      if CodevisorAppVariant.isDevelopment && !AppPreview.isRunning {
        SidebarDevelopmentWorktreeRow()
      }
      SidebarNewChatRow(selection: $selection, isHoverEnabled: !isReordering)
    }
    .padding(.horizontal, 10)
  }

  private var emptyPlaceholder: some View {
    SidebarPlaceholder(
      icon: Image(systemName: WorkspaceListEmptyCopy.systemImage), title: WorkspaceListEmptyCopy.title,
      message: WorkspaceListEmptyCopy.message
    )
    .allowsHitTesting(false)
  }

  private func workspaceGroupList(_ groups: [SidebarWorkspaceGroup], rows: [SidebarRow]) -> some View {
    workspaceRowList(rows)
      .padding(.horizontal, 10)
      .padding(.bottom, 8)
  }

  static let groupIndent: CGFloat = 8

  private var vibrantContent: some View {
    SidebarVibrancyHost {
      sidebarContent
        .environment(environment)
        .environment(\.isActiveSidebarMode, isActiveSidebarMode)
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
          onImport: { environment.importSessions($0.sessions, into: $0.project) }
        )
      )
      .modifier(WorkspaceRenamePrompt(request: $renamingWorkspace))
      .modifier(SectionPromptModifier(prompt: $sectionPrompt, store: environment.workspaceSections))
  }

  private var sidebarConfiguredView: some View {
    sidebarAlertsView
      .onChange(of: workspaceSectionIDs) { previous, current in
        followArchivedSelection(from: previous, to: current)
      }
      .forgetsPlacementOfArchivedWorkspaces()
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
  @Previewable @State var selection = LocalSidebarSelection()
  return NavigationSplitView {
    SidebarView(selection: SidebarSelectionRef(selection))
      .environment(AppEnvironment.preview())
  } detail: {
    Text("Detail")
  }
  .frame(width: 900, height: 600)
}
