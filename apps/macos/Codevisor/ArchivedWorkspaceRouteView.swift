import CodevisorCore
import SwiftUI

/// An archived workspace, read-only: its tabs as they were left, each showing
/// its selected pane. Chats show their history without a composer and never
/// start an agent; terminals and files went with the archive, so those panes
/// say so. Restoring, from the sidebar row, is the way back to a live
/// workspace.
///
/// Its own view rather than the live container: nothing here can add, close,
/// split, or rearrange a tab, so none of those paths need an archived guard.
struct ArchivedWorkspaceRouteView: View {
  @Environment(AppEnvironment.self) private var environment
  let store: SessionStore
  let serverId: String
  let workspaceId: UUID
  /// The workspace stopped being archived: restored from its sidebar row
  /// or on another device. The caller moves the selection to the live workspace.
  let onRestored: (Workspace) -> Void
  /// The tab shown; nil starts on the tab the workspace last showed.
  @State private var selectedTabId: UUID?
  @State private var focus = TerminalFocusController()

  var body: some View {
    let workspace = environment.navigationStore.workspaceEntries.entry(workspaceId).workspace
      .flatMap { $0.serverId == serverId ? $0 : nil }
    Group {
      if let workspace, workspace.isArchived {
        content(workspace)
          .navigationTitle(SidebarWorkspaceRowLabel.title(for: workspace.name))
          .navigationSubtitle("Archived")
      } else if workspace == nil {
        ContentUnavailableView(
          "Workspace Unavailable",
          systemImage: "rectangle.on.rectangle.slash",
          description: Text("This workspace is no longer available on its machine.")
        )
      }
    }
    .onChange(of: workspace?.isArchived, initial: true) { _, isArchived in
      if isArchived == false, let workspace { onRestored(workspace) }
    }
  }

  private func content(_ workspace: Workspace) -> some View {
    let tabs = workspace.centerTabs
    let tab = tabs.first { $0.id == selectedTabId } ?? workspace.selectedCenterTab ?? tabs.first
    return VStack(spacing: 0) {
      // The live workspace's strip, minus every edit: switching only.
      if tabs.count > 1, let tab {
        WorkspaceTabBar(
          items: tabs.map { tabItem($0, in: workspace) },
          selectedTabId: tab.id,
          onSelect: { selectedTabId = $0 }
        )
      }
      if let tab, let pane = selectedPane(of: tab) {
        paneContent(pane, in: workspace)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView(
          "No Tabs",
          systemImage: "rectangle.dashed",
          description: Text("This workspace had no tabs open when it was archived.")
        )
      }
    }
  }

  /// The pane the tab last showed: its active split's selected pane, else
  /// its first.
  private func selectedPane(of tab: WorkspaceTab) -> PaneDescriptorState? {
    tab.root.group(id: tab.activeLeafId)?.selectedPane ?? tab.root.allGroups.first?.state.panes.first
  }

  private func tabItem(_ tab: WorkspaceTab, in workspace: Workspace) -> PaneTabStripItem {
    let pane = selectedPane(of: tab)
    let chatTitle = pane?.chatSessionId.flatMap {
      environment.projectList.session($0, serverId: workspace.serverId)?.title
    }
    let title = tab.displayTitle(for: pane, chatTitle: chatTitle)
    return PaneTabStripItem(
      id: tab.id,
      name: title,
      icon: .workspaceTab(
        pane, title: title, serverId: workspace.serverId, environment: environment, store: store),
      canClose: false
    )
  }

  @ViewBuilder
  private func paneContent(_ pane: PaneDescriptorState, in workspace: Workspace) -> some View {
    switch pane.kind {
    case .chat:
      if let id = pane.chatSessionId,
        let session = environment.projectList.session(id, serverId: workspace.serverId),
        session.hasAgentSession,
        let project = environment.projectList.projects.first(where: {
          $0.serverId == workspace.serverId && $0.id == session.projectId
        })
      {
        ArchivedChatPane(session: session, project: project, paneId: pane.id, store: store, focus: focus)
      } else {
        ContentUnavailableView(
          "No Chat History",
          systemImage: "bubble.left.and.exclamationmark.bubble.right",
          description: Text("This chat has nothing to show.")
        )
      }
    case .newTab:
      ContentUnavailableView(
        "Empty Tab",
        systemImage: "rectangle.dashed",
        description: Text("Nothing was open in this tab.")
      )
    case .terminal:
      ContentUnavailableView(
        "Terminal Ended",
        systemImage: "terminal",
        description: Text("This terminal ended when the workspace was archived.")
      )
    default:
      ContentUnavailableView(
        pane.displayName,
        systemImage: "archivebox",
        description: Text("Restore the workspace to open this tab.")
      )
    }
  }
}

/// An archived chat's history, read-only: no composer, and no agent. Opening
/// the chat only reads its transcript; the server refuses prompts while its
/// workspace is archived.
private struct ArchivedChatPane: View {
  let session: ChatSession
  let project: Project
  let paneId: UUID
  let store: SessionStore
  let focus: TerminalFocusController

  var body: some View {
    let controller = store.controller(for: session, project: project)
    ChatScreen(
      controller: controller,
      focus: focus,
      presentationSurface: store.transcriptSurface(for: session, paneID: paneId, controller: controller),
      isReadOnly: true
    )
    .id(session.id)
    // A read-only chat screen does not connect on its own.
    .task(id: SessionStore.SessionKey(session)) {
      store.noteAccess(SessionStore.SessionKey(session))
      await controller.connectIfNeeded()
    }
    .onChange(of: session, initial: true) { _, updatedSession in
      store.reconcile(controller, for: updatedSession, project: project)
    }
  }
}
