import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import ComposableArchitecture
import SimulatorPane
import SwiftUI

extension SessionContainerView {
  @ViewBuilder
  var titledContentColumn: some View {
    if let model = activeFileModel {
      contentColumn.navigationTitle(model.title)
    } else {
      contentColumn.navigationTitle(activePaneTitle)
    }
  }

  private var activeToolbarGroup: PaneGroupModel? {
    let workspace = selectedWorkspace
    guard let leafId = workspace.selectedCenterTab?.resolvedActiveLeafId(preferred: activeLeafId) else { return nil }
    return configuredCenterModel(leafId: leafId)
  }

  var activePaneDescriptor: PaneDescriptorState? {
    guard let leafId = activeLeafId else { return nil }
    return selectedWorkspace.selectedPane(inLeaf: leafId)
  }

  var activeBrowserModel: ChromiumBrowserModel? {
    guard let group = activeToolbarGroup, group.state.selectedPane?.kind == .browser else { return nil }
    return (group.selectedPane as? BrowserPane)?.model
  }

  var activeFileModel: FilePaneModel? {
    guard let group = activeToolbarGroup, group.state.selectedPane?.kind == .document else { return nil }
    return (group.selectedPane as? FilePane)?.model
  }

  var activeReviewModel: ReviewPaneModel? {
    guard let group = activeToolbarGroup, group.state.selectedPane?.kind == .review else { return nil }
    return (group.selectedPane as? ReviewPane)?.model
  }

  var activeSimulatorModel: SimulatorPaneModel? {
    guard let group = activeToolbarGroup, group.state.selectedPane?.kind == .simulator else { return nil }
    return (group.selectedPane as? AppleSimulatorPane)?.model
  }

  var activeScreenSharingPane: ScreenSharingPane? {
    guard let group = activeToolbarGroup, group.state.selectedPane?.kind == .screenSharing,
      let pane = group.selectedPane as? ScreenSharingPane, pane.store != nil
    else { return nil }
    return pane
  }

  var paneControlsReplaceTitle: Bool {
    activePaneDescriptor?.kind == .browser || activeFileModel != nil || activeReviewModel != nil
      || activeSimulatorModel?.device != nil
  }

  var activePaneTitle: Binding<String> {
    Binding(
      get: {
        if let pane = activeScreenSharingPane { return pane.connectionName }
        if let device = activeSimulatorModel?.device { return device.name }
        guard let descriptor = activePaneDescriptor else { return "New Tab" }
        if descriptor.kind == .browser { return "" }
        let workspace = selectedWorkspace
        if descriptor.kind == .chat { return paneTitle(descriptor) }
        return workspace.selectedCenterTab?.customTitle ?? paneTitle(descriptor)
      },
      set: { title in
        guard !paneControlsReplaceTitle, activeScreenSharingPane == nil, activeFileModel == nil,
          activeSimulatorModel?.device == nil
        else { return }
        let workspace = selectedWorkspace
        renameCenterTab(workspace.selectedCenterTabId, to: title)
      }
    )
  }

  var activePaneSubtitle: String {
    guard let store = activeScreenSharingPane?.store,
      let display = store.displays.first(where: { $0.id == store.selectedDisplayId }),
      display.width > 0
    else { return "" }
    return "\(display.width) × \(display.height)"
  }
}
