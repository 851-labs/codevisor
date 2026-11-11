import CodevisorCore
import CodevisorUI
import Foundation

extension SessionContainerView {
  var pluginAppPresenter: PluginAppPresenter? {
    guard !isTabless else { return nil }

    return PluginAppPresenter(opensInSplit: true) { resource, chatSessionId, placement in
      openPluginApp(resource, chatSessionId: chatSessionId, placement: placement)
    }
  }

  func openPluginApp(
    _ resource: PluginAppPaneResource, chatSessionId: UUID?, placement: PluginAppPanePlacement
  ) -> PluginAppPanePlacement? {
    var workspace = selectedWorkspace
    if let existing = workspace.allPanes.first(where: { $0.pluginApp?.viewId == resource.viewId }) {
      store.selectDestination(.pane(existing.id), in: workspace.id)
      focusSelectedCenterPane()
      return placement
    }
    guard let chatPane = chatSessionId.flatMap(workspace.pane(containingChat:)) else { return nil }

    let pane = Self.pluginAppPane(resource, ownerChatSessionId: chatSessionId)
    let chatLeaf = workspace.centerTabs.lazy.compactMap { $0.root.groupId(containingPane: chatPane.id) }.first
    let fits = placement == .split && chatLeaf.map { splitDragCoordinator.canSplitLeaf($0, on: .trailing) } == true
    let opened: PluginAppPanePlacement = fits ? .split : .tab
    let destination: BrowserLinkDestination = fits ? .split(.trailing) : .foregroundTab
    guard let inserted = workspace.insertPane(pane, besidePane: chatPane.id, destination: destination) else {
      return nil
    }
    environment.workspaces.save(workspace)
    store.reconcileMountedPaneGroups(in: workspace)
    environment.workspaceSync.publishPane(
      pane, workspaceId: workspace.id, client: environment.machines.client(for: workspace.serverId))
    store.selectDestination(.tab(inserted.tabId), in: workspace.id)
    focusSelectedCenterPane()
    return opened
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
