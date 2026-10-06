import CodevisorCore
import SimulatorPane
import SwiftUI

extension WorkspaceScreen {
  var activeSimulatorModel: SimulatorPaneModel? {
    guard let pane = activePane, pane.kind == .simulator else { return nil }
    return simulatorPaneModel(for: pane)
  }

  /// A Simulator pane's actions beside the workspace's New Tab button, and the device's own
  /// controls along the bottom bar. (Its device is the screen's title, and the pane adds the title menu.)
  @ToolbarContentBuilder var simulatorToolbar: some ToolbarContent {
    if let model = activeSimulatorModel {
      SimulatorPaneToolbar(model: model) { data, name in
        SimulatorScreenshotSharing.share(data, deviceName: name)
      }
    }
  }

  /// A Simulator pane's title once it shows a device: its name.
  var simulatorTitle: String? { activeSimulatorModel?.device?.name }

  func simulatorPaneModel(for pane: PaneDescriptorState) -> SimulatorPaneModel? {
    guard let workspace = resolvedWorkspace else { return nil }
    let machines = environment.machines
    let serverId = resolvedServerId
    let client = machines.client(for: serverId)
    let model = SimulatorPaneCache.shared.model(for: pane.id) {
      SimulatorPaneModel(
        client: client, preferences: pane.simulator, workspaceId: workspace.id, paneId: pane.id,
        openTunnel: { await machines.tunnelMediaRoute(forMachineId: serverId) })
    }
    // Another device may have picked a different simulator for this pane.
    model.applyPreferences(pane.simulator ?? SimulatorPanePreferences())
    model.onPreferencesChanged = { updateSimulator(pane, preferences: $0) }
    return model
  }

  func convertToSimulator(_ pane: PaneDescriptorState) {
    guard let workspaceSessionId = paneStorageId else { return }
    var state = panes
    let converted = state.convertNewTabPane(id: pane.id, to: .simulator, sessionId: workspaceSessionId)
    paneBinding.wrappedValue = state
    if let converted { publishPane(converted) }
  }

  private func updateSimulator(_ pane: PaneDescriptorState, preferences: SimulatorPanePreferences) {
    var state = panes
    guard let index = state.panes.firstIndex(where: { $0.id == pane.id }),
      state.panes[index].simulator != preferences
    else { return }
    state.panes[index].simulator = preferences
    paneBinding.wrappedValue = state
    publishPane(state.panes[index])
  }
}
