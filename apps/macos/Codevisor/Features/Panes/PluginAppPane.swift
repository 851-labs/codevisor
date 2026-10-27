import CodevisorCore
import CodevisorUI
import SwiftUI

@MainActor
final class PluginAppPane: Pane, Identifiable {
  let id: UUID
  let kind: PaneKind = .plugin
  let descriptor: PaneDescriptorState
  let machineId: String

  var onGroupCommand: ((PaneGroupCommand) -> Void)?
  var onFocusChanged: ((Bool) -> Void)?

  init(context: PaneContext, descriptor: PaneDescriptorState) {
    self.id = descriptor.id
    self.descriptor = descriptor
    self.machineId = context.machine.id
  }

  func makeView() -> AnyView {
    AnyView(PluginAppPaneHost(pane: self))
  }

  func model(environment: AppEnvironment) -> PluginAppPaneModel? {
    let model = PluginAppPaneModels.shared.model(
      for: descriptor, fallbackMachineId: machineId, environment: environment)
    model?.onBack = { [weak self] in self?.onGroupCommand?(.closeTab) }
    return model
  }

  func focus() {}

  func visibilityChanged(_ visible: Bool) {}

  func willDelete() async {
    PluginAppPaneModels.shared.remove(paneId: id)
  }

  func detach() {
    PluginAppPaneModels.shared.existing(paneId: id)?.suspend()
  }
}
