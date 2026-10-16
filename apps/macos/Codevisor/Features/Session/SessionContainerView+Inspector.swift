import CodevisorCore
import SwiftUI

extension SessionContainerView {
  func openInspectorDestination(_ destination: WorkspaceInspectorView.Destination) {
    switch destination {
    case let .pullRequest(url), let .link(url):
      let id = UUID()
      openCenterTab(
        with: PaneDescriptorState(
          id: id, kind: .browser, name: "Browser", terminalKey: id.uuidString, browserURL: url.absoluteString)
      )
    case let .file(path):
      _ = openFileDocument(path)
    }
  }

  private func openCenterTab(with pane: PaneDescriptorState) {
    var workspace = selectedWorkspace
    let tab = WorkspaceTab(root: .leaf(PaneGroupState(panes: [pane], selectedPaneId: pane.id)))
    workspace.centerTabs.append(tab)
    environment.workspaces.save(workspace)
    store.selectDestination(.tab(tab.id), in: workspace.id)
    publishPane(pane, workspaceId: workspace.id)
    focusSelectedCenterPane()
  }
}
