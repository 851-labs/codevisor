import CodevisorCore
import ScreenSharingPane
import SimulatorPane
import SwiftUI

extension WorkspaceScreen {
  var activeSimulatorModel: SimulatorPaneModel? {
    guard let pane = activePane, pane.kind == .simulator else { return nil }
    return simulatorPaneModel(for: pane)
  }

  @ToolbarContentBuilder var simulatorToolbar: some ToolbarContent {
    if let model = activeSimulatorModel {
      SimulatorPaneToolbar(model: model) { data, name in
        SimulatorScreenshotSharing.share(data, deviceName: name)
      }
    }
  }

  var simulatorTitle: String? { activeSimulatorModel?.device?.name }

  func simulatorPaneModel(for pane: PaneDescriptorState) -> SimulatorPaneModel? {
    guard resolvedWorkspace != nil else { return nil }
    let machines = environment.machines
    let serverId = resolvedServerId
    let client = machines.client(for: serverId)
    let model = SimulatorPaneCache.shared.model(for: pane.id) {
      SimulatorPaneModel(
        client: client, preferences: pane.simulator, machineId: serverId,
        streams: simulatorStreams(onMachine: serverId))
    }
    model.applyPreferences(pane.simulator ?? SimulatorPanePreferences())
    model.onPreferencesChanged = { updateSimulator(pane, preferences: $0) }
    return model
  }

  private func simulatorStreams(onMachine machineId: String) -> SimulatorStreamSource {
    let environment = environment
    return SimulatorStreamSource(
      machineName: environment.machines.machine(for: machineId)?.name ?? "this machine",
      connection: { target in
        ScreenSharingDesktops.shared.targetConnection(onMachine: machineId, target: target, environment: environment)
      },
      end: { ScreenSharingDesktops.shared.endTargetConnection(onMachine: machineId, target: $0) })
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
