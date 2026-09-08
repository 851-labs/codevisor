import CodevisorCore
import SwiftUI

extension SessionContainerView {
  /// Resolve within the selected tab, even during the frame between a tab
  /// change and its focus callback. A stale split must never own browser commands.
  private var activeToolbarGroup: PaneGroupModel? {
    let _ = (workspaceRevision, store.workspaceLayoutRevision, environment.workspaceSync.revision)
    let workspace = store.workspace(for: session, project: project)
    guard let leafId = workspace.selectedCenterTab?.resolvedActiveLeafId(preferred: activeLeafId) else { return nil }
    return configuredCenterModel(leafId: leafId)
  }

  var activePaneDescriptor: PaneDescriptorState? { activeToolbarGroup?.state.selectedPane }

  var activeBrowserModel: ChromiumBrowserModel? {
    guard let group = activeToolbarGroup, group.state.selectedPane?.kind == .browser else { return nil }
    return (group.selectedPane as? BrowserPane)?.model
  }

  /// Chats retain the editable title and context previously used in Nous.
  /// Other pane types name themselves; browser controls replace the title.
  var activePaneTitle: Binding<String> {
    Binding(
      get: {
        guard let descriptor = activePaneDescriptor else { return "New Tab" }
        if descriptor.kind == .browser { return "" }
        let workspace = store.workspace(for: session, project: project)
        return workspace.selectedCenterTab?.customTitle ?? paneTitle(descriptor)
      },
      set: { title in
        guard activePaneDescriptor?.kind != .browser else { return }
        let workspace = store.workspace(for: session, project: project)
        renameCenterTab(workspace.selectedCenterTabId, to: title)
      }
    )
  }

  var activePaneSubtitle: String {
    let workspace = store.workspace(for: session, project: project)
    let candidates: [String?] = [
      workspace.name,
      project.name,
      workspace.worktreeName,
      environment.machines.fleetMachineName(for: session.serverId),
    ]
    var parts: [String] = []
    for candidate in candidates {
      guard let candidate, !candidate.isEmpty, !parts.contains(candidate) else { continue }
      parts.append(candidate)
    }
    return parts.joined(separator: " · ")
  }
}
