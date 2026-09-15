import CodevisorCore
import CodevisorCoreMac
import ComposableArchitecture
import SwiftUI

extension SessionContainerView {
  /// Resolve within the selected tab, even during the frame between a tab
  /// change and its focus callback. A stale split must never own pane controls.
  private var activeToolbarGroup: PaneGroupModel? {
    let _ = (workspaceRevision, store.workspaceLayoutRevision, environment.workspaceSync.revision)
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

  var activeScreenSharingPane: ScreenSharingPane? {
    guard let group = activeToolbarGroup, group.state.selectedPane?.kind == .screenSharing,
      let pane = group.selectedPane as? ScreenSharingPane, pane.store != nil, !pane.showsDisplayPicker
    else { return nil }
    return pane
  }

  var paneControlsReplaceTitle: Bool {
    activePaneDescriptor?.kind == .browser
  }

  /// Chats retain the editable title and context previously used in Nous.
  /// Connected screen sharing names the remote Mac; browser controls replace the title.
  var activePaneTitle: Binding<String> {
    Binding(
      get: {
        if let pane = activeScreenSharingPane { return pane.machineName }
        guard let descriptor = activePaneDescriptor else { return "New Tab" }
        if paneControlsReplaceTitle { return "" }
        let workspace = selectedWorkspace
        return workspace.selectedCenterTab?.customTitle ?? paneTitle(descriptor)
      },
      set: { title in
        guard !paneControlsReplaceTitle, activeScreenSharingPane == nil else { return }
        let workspace = selectedWorkspace
        renameCenterTab(workspace.selectedCenterTabId, to: title)
      }
    )
  }

  var activePaneSubtitle: String {
    if let store = activeScreenSharingPane?.store {
      guard let display = store.displays.first(where: { $0.id == store.selectedDisplayId }) else { return "" }
      return "\(display.width) × \(display.height)"
    }
    guard activePaneDescriptor?.kind == .chat else { return "" }
    let workspace = selectedWorkspace
    let candidates: [String?] = [
      workspace.name,
      project.name,
      workspace.worktreeName,
      environment.machines.fleetMachineName(for: workspace.serverId),
    ]
    var parts: [String] = []
    for candidate in candidates {
      guard let candidate, !candidate.isEmpty, !parts.contains(candidate) else { continue }
      parts.append(candidate)
    }
    return parts.joined(separator: " · ")
  }
}
