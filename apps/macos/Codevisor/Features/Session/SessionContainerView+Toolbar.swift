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
    if let model = activeFileModel { return .fixed(model.title) }
    guard let chat = activeMainChat else { return .fixed(activePaneTitle) }
    return .editable(title(renaming: chat))
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
      FilePaneToolbar(model: model)
    } else {
      reviewOrSimulatorToolbar
    }
  }

  @ToolbarContentBuilder
  private var reviewOrSimulatorToolbar: some ToolbarContent {
    if let model = activeReviewModel {
      ReviewPaneToolbar(model: model, title: activePaneTitle)
    } else if let model = activeSimulatorModel {
      SimulatorPaneToolbar(model: model) { data, name in
        AppleSimulatorPane.saveScreenshot(data, deviceName: name)
      }
    }
  }

  private var activeToolbarSource: PaneToolbarSource? {
    let workspace = selectedWorkspace
    guard let leafId = workspace.selectedCenterTab?.resolvedActiveLeafId(preferred: activeLeafId),
      !isFloating(leafId)
    else { return nil }
    return PaneToolbarSource(group: configuredCenterModel(leafId: leafId))
  }

  var activePaneDescriptor: PaneDescriptorState? {
    guard let leafId = activeLeafId else { return nil }
    return selectedWorkspace.selectedPane(inLeaf: leafId)
  }

  var activeBrowserModel: ChromiumBrowserModel? { activeToolbarSource?.browser }

  var activeFileModel: FilePaneModel? { activeToolbarSource?.file }

  var activeReviewModel: ReviewPaneModel? { activeToolbarSource?.review }

  var activeSimulatorModel: SimulatorPaneModel? { activeToolbarSource?.simulator }

  var activeScreenSharingPane: ScreenSharingPane? { activeToolbarSource?.screenSharing }

  var paneControlsReplaceTitle: Bool {
    activePaneDescriptor?.kind == .browser || activeFileModel != nil || activeReviewModel != nil
      || activeSimulatorModel?.device != nil
  }

  var activePaneTitle: String {
    if let pane = activeScreenSharingPane { return pane.connectionName }
    if let device = activeSimulatorModel?.device { return device.name }
    guard let descriptor = activePaneDescriptor else { return "New Tab" }
    if descriptor.kind == .browser { return "" }
    return paneTitle(descriptor)
  }

  private var activeMainChat: ChatSession? {
    let workspace = selectedWorkspace
    guard let descriptor = activePaneDescriptor, workspace.isMainChatPane(descriptor),
      let id = descriptor.chatSessionId
    else { return nil }
    return environment.projectList.session(id, serverId: workspace.serverId)
  }

  private func title(renaming chat: ChatSession) -> Binding<String> {
    Binding(
      get: { activePaneTitle },
      set: { environment.projectList.renameSession(chat, to: $0) }
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
