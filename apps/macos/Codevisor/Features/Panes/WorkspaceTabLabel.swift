import CodevisorCore
import SwiftUI

struct WorkspaceTabLabel {
  let title: String
  let icon: PaneTabIcon
  let isPreview: Bool
  let isSplit: Bool

  init(_ tab: WorkspaceTab, in workspace: Workspace, environment: AppEnvironment, store: SessionStore) {
    let descriptor = Self.descriptor(of: tab, in: workspace, store: store)
    let title = Self.title(showing: descriptor, in: workspace, environment: environment, store: store)
    self.title = title
    icon = .workspaceTab(descriptor, title: title, serverId: workspace.serverId, environment: environment, store: store)
    isPreview = tab.isPreview
    isSplit = tab.root.allGroups.count > 1
  }

  var unreadChat: ChatSession? {
    icon.chatSession
  }

  private static func descriptor(
    of tab: WorkspaceTab, in workspace: Workspace, store: SessionStore
  ) -> PaneDescriptorState? {
    let persisted = tab.root.group(id: tab.activeLeafId)
    let liveKey = SessionStore.CenterLeafKey(workspaceId: workspace.id, groupId: tab.activeLeafId)
    guard var live = store.centerLeafGroups[liveKey]?.state.selectedPane else {
      return persisted?.selectedPane ?? tab.root.allGroups.first?.state.selectedPane
    }
    if let record = persisted?.panes.first(where: { $0.id == live.id }) {
      live.liveTitle = record.liveTitle
      live.terminalActivity = record.terminalActivity
    }
    return live
  }

  private static func title(
    showing descriptor: PaneDescriptorState?, in workspace: Workspace, environment: AppEnvironment, store: SessionStore
  ) -> String {
    guard let descriptor else { return "New Tab" }
    if descriptor.kind == .browser, let title = store.localBrowserTitle(paneId: descriptor.id) { return title }
    guard descriptor.kind == .chat else { return descriptor.displayName }
    guard let id = descriptor.chatSessionId,
      let chat = environment.projectList.chat(id, preferring: workspace.serverId)
    else { return descriptor.name }
    return workspace.title(ofChat: chat)
  }
}
