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
    return ScreenSharingDesktops.shared.model(
      for: resolvedServerId, showing: workspace.id, seedDisplayId: pane.screenSharing?.preferredDisplayId,
      environment: environment)
  }

  func convertToScreenSharing(_ pane: PaneDescriptorState) {
    guard let workspaceSessionId = paneStorageId else { return }
    var state = panes
    let converted = state.convertNewTabPane(id: pane.id, to: .screenSharing, sessionId: workspaceSessionId)
    paneBinding.wrappedValue = state
    guard let converted else { return }
    publishPane(converted)
    screenSharingPaneModel(for: converted)?.openedByUser(pane: converted.id)
  }
}
