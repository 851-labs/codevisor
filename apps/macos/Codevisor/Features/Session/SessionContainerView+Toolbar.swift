import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import ComposableArchitecture
import SwiftUI

extension SessionContainerView {
  @ViewBuilder
  var titledContentColumn: some View {
    if let model = activeFileModel {
      // Keep the window's document title while the toolbar supplies a browse button.
      contentColumn.navigationTitle(model.title)
    } else {
      contentColumn.navigationTitle(activePaneTitle)
    }
  }

  /// Resolve within the selected tab, even during the frame between a tab
  /// change and its focus callback. A stale split must never own pane controls.
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

  var activeScreenSharingPane: ScreenSharingPane? {
    guard let group = activeToolbarGroup, group.state.selectedPane?.kind == .screenSharing,
      let pane = group.selectedPane as? ScreenSharingPane, pane.store != nil
    else { return nil }
    return pane
  }

  var paneControlsReplaceTitle: Bool {
    activePaneDescriptor?.kind == .browser || activeFileModel != nil
  }

  /// Chats retain the editable title and context previously used in Nous.
  /// Connected screen sharing names the remote Mac; browser and file controls replace the title.
  var activePaneTitle: Binding<String> {
    Binding(
      get: {
        if let pane = activeScreenSharingPane { return pane.connectionName }
        guard let descriptor = activePaneDescriptor else { return "New Tab" }
        if descriptor.kind == .browser { return "" }
        let workspace = selectedWorkspace
        if descriptor.kind == .chat { return paneTitle(descriptor) }
        return workspace.selectedCenterTab?.customTitle ?? paneTitle(descriptor)
      },
      set: { title in
        guard !paneControlsReplaceTitle, activeScreenSharingPane == nil, activeFileModel == nil else { return }
        let workspace = selectedWorkspace
        renameCenterTab(workspace.selectedCenterTabId, to: title)
      }
    )
  }

  var activePaneSubtitle: String {
    if let store = activeScreenSharingPane?.store {
      guard let display = store.displays.first(where: { $0.id == store.selectedDisplayId }), display.width > 0 else {
        return ""
      }
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
