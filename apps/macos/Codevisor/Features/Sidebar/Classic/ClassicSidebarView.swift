import SwiftUI
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import os

struct ClassicSidebarView: View {
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
  @State var drag: ClassicSidebarDrag?
  @State var dragGeometry = ClassicSidebarDragGeometryStore()

  var list: ProjectListModel { environment.projectList }
  var isReordering: Bool { drag != nil }
  var itemTitleFont: Font { .body }

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

      ScrollView {
        workspaceList(listedSidebarItems)
      }
      .scrollContentBackground(.hidden)
      .scrollBounceBehavior(.basedOnSize)

      SidebarSyncFooter(indicator: environment.navigationSyncIndicator)
      SidebarUpdateFooter(center: environment.updateCenter)
    }
    .coordinateSpace(.named(Self.reorderSpace))
    .overlay(alignment: .topLeading) { reorderOverlay }
  }

  private func workspaceList(_ items: [WorkspaceSidebarItem]) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      ForEach(items) { item in
        ClassicSidebarWorkspaceSection(
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
      .task(id: store.map(ObjectIdentifier.init)) {
        guard publishesSceneActions else { return }
        store?.sidebarTabStepHandler = { offset in stepSidebarTab(offset) }
      }
      .onDisappear {
        if publishesSceneActions { store?.sidebarTabStepHandler = nil }
      }
      .focusedSceneValue(
        \.sidebarActions,
        publishesSceneActions && store != nil
          ? SidebarActions(
            newChat: { selection = .newChat(nil) },
            newProject: { startAddProject() },
            stepTab: { _ = stepSidebarTab($0) }
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
    ClassicSidebarView(selection: $selection)
      .environment(AppEnvironment.preview())
  } detail: {
    Text("Detail")
  }
  .frame(width: 900, height: 600)
}
