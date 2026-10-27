import CodevisorCore
import CodevisorUI
import Foundation

extension SessionContainerView {
  var pluginAppPresenter: PluginAppPresenter? {
    guard !isSinglePane else { return nil }

    return PluginAppPresenter(open: { resource, chatSessionId in
      openPluginApp(resource, chatSessionId: chatSessionId)
    })
  }

  func openPluginApp(_ resource: PluginAppPaneResource, chatSessionId: UUID?) -> Bool {
    var workspace = selectedWorkspace
    if let existing = workspace.allPanes.first(where: { $0.pluginApp?.viewId == resource.viewId }) {
      store.selectDestination(.pane(existing.id), in: workspace.id)
      focusSelectedCenterPane()
      return true
    }
    guard let chatPane = chatSessionId.flatMap(workspace.pane(containingChat:)) else { return false }

    let pane = Self.pluginAppPane(resource, ownerChatSessionId: chatSessionId)
    guard let inserted = workspace.insertPane(pane, besidePane: chatPane.id, destination: .foregroundTab) else {
      return false
    }
    environment.workspaces.save(workspace)
    store.reconcileMountedPaneGroups(in: workspace)
    environment.workspaceSync.publishPane(
      pane, workspaceId: workspace.id, client: environment.machines.client(for: workspace.serverId))
    store.selectDestination(.tab(inserted.tabId), in: workspace.id)
    focusSelectedCenterPane()
    return true
  }

  private static func pluginAppPane(
    _ resource: PluginAppPaneResource, ownerChatSessionId: UUID?
  ) -> PaneDescriptorState {
    let id = UUID()
    return PaneDescriptorState(
      id: id, kind: .plugin, name: resource.serverName, terminalKey: id.uuidString,
      ownerChatSessionId: ownerChatSessionId, pluginId: resource.serverId, pluginApp: resource)
  }
}
