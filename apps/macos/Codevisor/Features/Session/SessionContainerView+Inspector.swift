import CodevisorCore
import SwiftUI

extension SessionContainerView {
  func openInspectorDestination(_ destination: WorkspaceInspectorView.Destination) {
    guard !isSinglePane else { return botPageInspectorOpener.open(destination) }
    switch destination {
    case let .pullRequest(url), let .link(url):
      let id = UUID()
      openCenterTab(
        with: PaneDescriptorState(
          id: id, kind: .browser, name: "Browser", terminalKey: id.uuidString, browserURL: url.absoluteString)
      )
    case let .file(path):
      _ = openFileDocument(path)
    case let .previewFile(path):
      _ = openFileDocument(path, preview: true)
    case .botTranscript:
      let workspace = selectedWorkspace
      guard botsEnabled,
        let bot = environment.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId)
      else { return }
      openBotTranscript(bot)
    }
  }

  private var botPageInspectorOpener: BotPageInspectorOpener {
    BotPageInspectorOpener(
      workspace: selectedWorkspace,
      rootDirectory: selectedWorkspace.rootDirectory ?? session?.cwd ?? project.folderURL.path,
      environment: environment, store: store, quickLook: quickLook)
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
