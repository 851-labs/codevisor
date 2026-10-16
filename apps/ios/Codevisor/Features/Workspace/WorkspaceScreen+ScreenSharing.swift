import CodevisorCore
import ScreenSharingPane
import SwiftUI

extension WorkspaceScreen {
  var activeScreenSharingModel: ScreenSharingPaneModel? {
    guard let pane = activePane, pane.kind == .screenSharing else { return nil }
    return screenSharingPaneModel(for: pane)
  }

  @ToolbarContentBuilder var screenSharingToolbar: some ToolbarContent {
    if let model = activeScreenSharingModel {
      ScreenSharingPaneToolbar(model: model)
    }
  }

  var screenSharingTitle: String? {
    guard let model = activeScreenSharingModel else { return nil }
    return model.selectedDisplay?.name ?? "Desktop"
  }

  func screenSharingPaneModel(for pane: PaneDescriptorState) -> ScreenSharingPaneModel? {
    guard let workspace = resolvedWorkspace else { return nil }
    let machines = environment.machines
    let serverId = resolvedServerId
    let client = machines.client(for: serverId)
    let model = ScreenSharingPaneCache.shared.model(for: pane.id) {
      ScreenSharingPaneModel(
        client: client, preferences: pane.screenSharing, workspaceId: workspace.id, paneId: pane.id,
        openTunnel: { await machines.tunnelMediaRoute(forMachineId: serverId) })
    }
    model.applyPreferences(pane.screenSharing ?? ScreenSharingPanePreferences())
    model.onPreferencesChanged = { updateScreenSharing(pane, preferences: $0) }
    return model
  }

  func convertToScreenSharing(_ pane: PaneDescriptorState) {
    guard let workspaceSessionId = paneStorageId else { return }
    var state = panes
    let converted = state.convertNewTabPane(id: pane.id, to: .screenSharing, sessionId: workspaceSessionId)
    paneBinding.wrappedValue = state
    if let converted { publishPane(converted) }
  }

  private func updateScreenSharing(_ pane: PaneDescriptorState, preferences: ScreenSharingPanePreferences) {
    var state = panes
    guard let index = state.panes.firstIndex(where: { $0.id == pane.id }),
      state.panes[index].screenSharing != preferences
    else { return }
    state.panes[index].screenSharing = preferences
    paneBinding.wrappedValue = state
    publishPane(state.panes[index])
  }
}
