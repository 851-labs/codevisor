import CodevisorCore
import CodevisorUI
import Foundation

extension SessionStore {
  func openBrowserLink(
    for session: ChatSession, project: Project, sourcePaneId: UUID, url: String,
    destination: BrowserLinkDestination, popup: CVChromiumView?
  ) -> Bool {
    guard popup != nil || BrowserLocation.navigationURL(url) != nil else { return false }
    var workspace = workspace(for: session, project: project)
    let paneId = UUID()
    let pane = PaneDescriptorState(
      id: paneId, kind: .browser, name: "Browser", terminalKey: paneId.uuidString,
      browserURL: BrowserLocation.sharedURL(url)?.absoluteString)
    guard let placement = workspace.insertBrowserPane(pane, from: sourcePaneId, destination: destination) else {
      return false
    }
    environment.workspaces.save(workspace)
    let group = centerGroup(leafId: placement.leafId, workspace: workspace, session: session, project: project)
    guard let browser = group.pane(for: pane) as? BrowserPane else { return false }
    if let popup {
      browser.model.adoptPopup(popup)
    } else {
      browser.model.automationInitialURL = url
      // Load background tabs immediately, using the same hidden native host as
      // Browser Use. Selecting the pane later reuses the live page.
      Task { _ = try? await browser.model.readyView() }
    }
    environment.workspaceSync.publishPane(
      pane, workspaceId: workspace.id, client: environment.machines.client(for: session.serverId))
    workspaceLayoutRevision += 1
    switch destination {
    case .backgroundTab: break
    case .foregroundTab, .split:
      centerTabRequest = CenterTabRequest(workspaceId: workspace.id, action: .select(placement.tabId))
    case .window:
      browser.model.presentInWindow()
    }
    return true
  }
}
