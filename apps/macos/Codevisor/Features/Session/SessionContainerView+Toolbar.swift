import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import ComposableArchitecture
import SimulatorPane
import SwiftUI

extension SessionContainerView {
  var chrome: WorkspaceChrome {
    let source = activeToolbarSource
    return WorkspaceChrome(
      title: source?.file?.title ?? paneTitle(showing: source),
      renamedChat: source?.file == nil ? renamedChat : nil,
      removesTitle: hidesWorkspaceTitle || paneControlsReplaceTitle(source),
      toolbar: source,
      layoutActions: layoutActions(in: selectedWorkspace),
      handlers: handlerIdentity
    )
  }

  var activePaneDescriptor: PaneDescriptorState? {
    guard let leafId = activeLeafId else { return nil }
    return selectedWorkspace.selectedPane(inLeaf: leafId)
  }

  var activeBrowserModel: ChromiumBrowserModel? { activeToolbarSource?.browser }

  private var activeToolbarSource: PaneToolbarSource? {
    let workspace = selectedWorkspace
    guard let leafId = workspace.selectedCenterTab?.resolvedActiveLeafId(preferred: activeLeafId),
      !isFloating(leafId)
    else { return nil }
    return PaneToolbarSource(group: configuredCenterModel(leafId: leafId))
  }

  private var renamedChat: WorkspaceChrome.RenamedChat? {
    let workspace = selectedWorkspace
    guard let descriptor = activePaneDescriptor, workspace.isMainChatPane(descriptor),
      let id = descriptor.chatSessionId,
      let chat = environment.projectList.chat(id, preferring: workspace.serverId)
    else { return nil }
    return WorkspaceChrome.RenamedChat(id: chat.id, serverId: chat.serverId)
  }

  private func paneControlsReplaceTitle(_ source: PaneToolbarSource?) -> Bool {
    activePaneDescriptor?.kind == .browser || source?.file != nil || source?.review != nil
      || source?.simulator?.device != nil
  }

  private func paneTitle(showing source: PaneToolbarSource?) -> String {
    if let pane = source?.screenSharing { return pane.connectionName }
    if let device = source?.simulator?.device { return device.name }
    guard let descriptor = activePaneDescriptor else { return "New Tab" }
    if descriptor.kind == .browser { return "" }
    return paneTitle(descriptor)
  }
}
