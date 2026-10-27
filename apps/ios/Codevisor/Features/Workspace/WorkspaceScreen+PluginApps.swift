import CodevisorCore
import CodevisorUI
import SwiftUI

extension WorkspaceScreen {
  var pluginAppPresenter: PluginAppPresenter {
    PluginAppPresenter(
      open: { resource, chatSessionId in openPluginApp(resource, chatSessionId: chatSessionId) },
      close: { paneId in closePluginApp(paneId) }
    )
  }

  func openPluginApp(_ resource: PluginAppPaneResource, chatSessionId: UUID?) -> Bool {
    var state = panes
    if let existing = state.panes.first(where: { $0.pluginApp?.viewId == resource.viewId }) {
      state.selectPane(id: existing.id)
      paneBinding.wrappedValue = state
      return true
    }
    guard let index = state.panes.firstIndex(where: { $0.chatSessionId != nil && $0.chatSessionId == chatSessionId })
    else { return false }

    let pane = Self.pluginAppPane(resource, ownerChatSessionId: chatSessionId)
    state.panes.insert(pane, at: index + 1)
    state.selectedPaneId = pane.id
    paneBinding.wrappedValue = state
    publishPane(pane)
    return true
  }

  private func closePluginApp(_ paneId: UUID) {
    guard let pane = panes.panes.first(where: { $0.id == paneId }) else { return }

    let owner = pane.ownerChatSessionId.flatMap { owner in panes.panes.first { $0.chatSessionId == owner } }
    close(pane)
    guard let owner else { return }

    var state = panes
    state.selectPane(id: owner.id)
    paneBinding.wrappedValue = state
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
