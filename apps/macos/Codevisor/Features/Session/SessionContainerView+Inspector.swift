import CodevisorCore
import SwiftUI

extension SessionContainerView {
  func openInspectorDestination(_ destination: WorkspaceInspectorView.Destination) {
    switch destination {
    case .changes: openCenterTab { $0.convertNewTabPane(id: $1, to: .review) }
    case .desktop: openCenterTab { $0.convertNewTabPane(id: $1, to: .screenSharing) }
    case .browser: openCenterTab { $0.convertNewTabPane(id: $1, to: .browser) }
    case .terminal: openCenterTab { $0.convertNewTabPane(id: $1, to: .terminal) }
    case .files: openCenterTab { $0.openFiles(id: $1) }
    case let .pullRequest(url), let .link(url):
      let id = UUID()
      openCenterTab(
        with: PaneDescriptorState(
          id: id, kind: .browser, name: "Browser", terminalKey: id.uuidString, browserURL: url.absoluteString)
      )
    }
  }

  private func openCenterTab(converting convert: (PaneGroupModel, UUID) -> Void) {
    var state = PaneGroupState()
    let pane = state.addNewTabPane()
    guard let group = openCenterTab(with: pane) else { return }
    convert(group, pane.id)
  }

  @discardableResult
  private func openCenterTab(with pane: PaneDescriptorState) -> PaneGroupModel? {
    var workspace = selectedWorkspace
    let tab = WorkspaceTab(root: .leaf(PaneGroupState(panes: [pane], selectedPaneId: pane.id)))
    workspace.centerTabs.append(tab)
    environment.workspaces.save(workspace)
    store.selectDestination(.tab(tab.id), in: workspace.id)
    publishPane(pane, workspaceId: workspace.id)
    focusSelectedCenterPane()
    return tab.root.allGroups.first.map { configuredCenterModel(leafId: $0.id) }
  }
}
