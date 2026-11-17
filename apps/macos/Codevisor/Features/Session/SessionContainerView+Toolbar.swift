import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import ComposableArchitecture
import SimulatorPane
import SwiftUI

extension SessionContainerView {
  var chrome: WorkspaceChrome {
    WorkspaceChrome(
      title: activeFileModel?.title ?? activePaneTitle,
      renamedChat: activeFileModel == nil ? renamedChat : nil,
      removesTitle: paneControlsReplaceTitle,
      toolbar: activeToolbarSource,
      layoutActions: layoutActions(in: selectedWorkspace)
    )
  }

  private var renamedChat: WorkspaceChrome.RenamedChat? {
    activeMainChat.map { WorkspaceChrome.RenamedChat(id: $0.id, serverId: $0.serverId) }
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
    return environment.projectList.chat(id, preferring: workspace.serverId)
  }
}
