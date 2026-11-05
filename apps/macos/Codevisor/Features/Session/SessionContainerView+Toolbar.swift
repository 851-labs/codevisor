import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import ComposableArchitecture
import SimulatorPane
import SwiftUI

extension SessionContainerView {
  var sceneChrome: some View {
    WorkspaceSceneChrome(
      title: sceneTitle, subtitle: activePaneSubtitle, removesTitle: paneControlsReplaceTitle,
      values: WorkspaceSceneValues(
        browser: activeBrowserModel, file: activeFileModel, simulator: activeSimulatorModel,
        layoutActions: layoutActions(in: selectedWorkspace))
    ) {
      paneToolbar
    }
  }

  private var sceneTitle: WorkspaceSceneTitle {
    guard let model = activeFileModel else { return .editable(activePaneTitle) }
    return .fixed(model.title)
  }

  @ToolbarContentBuilder
  private var paneToolbar: some ToolbarContent {
    if let browser = activeBrowserModel {
      ChromiumBrowserNavigationControls(model: browser)
      ChromiumBrowserAddressToolbarItem(model: browser)
    } else {
      machinePaneToolbar
    }
  }

  @ToolbarContentBuilder
  private var machinePaneToolbar: some ToolbarContent {
    if let pane = activeScreenSharingPane, let store = pane.store {
      ScreenSharingToolbar(
        store: store, settings: { pane.machineSettings() }, applySettings: { pane.applyMachineSettings($0) })
    } else {
      documentPaneToolbar
    }
  }

  @ToolbarContentBuilder
  private var documentPaneToolbar: some ToolbarContent {
    if let model = activeFileModel {
      FilePaneToolbar(model: model, onNewTab: addCenterTab)
    } else {
      reviewOrSimulatorToolbar
    }
  }

  @ToolbarContentBuilder
  private var reviewOrSimulatorToolbar: some ToolbarContent {
    if let model = activeReviewModel {
      ReviewPaneToolbar(model: model, title: activePaneTitle.wrappedValue)
    } else if let model = activeSimulatorModel {
      SimulatorPaneToolbar(model: model) { data, name in
        AppleSimulatorPane.saveScreenshot(data, deviceName: name)
      }
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
