import Foundation
import Testing
@testable import CodevisorCore

@MainActor
struct ClientControlTests {
  private func fixture() -> (DefaultWorkspaceRepository, Workspace, UUID) {
    let pane = PaneDescriptorState(
      id: UUID(), kind: .browser, name: "Docs", terminalKey: "browser"
    )
    let tabs = [
      WorkspaceTab(root: .leaf(.centerInitial(sessionId: UUID()))),
      WorkspaceTab(root: .leaf(PaneGroupState(panes: [pane], selectedPaneId: pane.id))),
    ]
    let workspace = Workspace(
      name: "Project", rootDirectory: "/fixture", serverId: "machine", projectId: UUID(),
      centerTabs: tabs, createdAt: Date(timeIntervalSince1970: 0)
    )
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    repository.save(workspace)
    return (repository, workspace, pane.id)
  }

  @Test("Navigation acknowledges the selected pane using the native workspace operation")
  func navigateAndRead() async throws {
    let (repository, workspace, paneId) = fixture()
    let request = ClientNavigationRequest(
      workspaceId: workspace.id, destination: .init(kind: .pane, id: paneId)
    )
    let response = await ClientControlConnection.handle(
      .init(requestId: "request", method: "navigate", navigation: request),
      context: { .capture(repository: repository, serverId: "machine", workspaceId: workspace.id, isActive: true) },
      navigate: { repository.save(try $0.applying(to: workspace)) }
    )
    #expect(response.error == nil)
    #expect(response.requestId == "request")
    #expect(response.context?.workspaceId == workspace.id)
    #expect(response.context?.workspaces.first?.paneId == paneId)
    #expect(repository.workspace(id: workspace.id)?.centerTabs == workspace.centerTabs)
    let data = try JSONEncoder().encode(response)
    let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(decoded["type"] as? String == "response")
  }

  @Test("Context is scoped to one machine and omits unavailable selected workspaces")
  func machineScope() {
    let (repository, workspace, _) = fixture()
    let other = NativeClientContext.capture(
      repository: repository, serverId: "other", workspaceId: workspace.id, isActive: false
    )
    #expect(other.workspaceId == nil)
    #expect(other.workspaces.isEmpty)
    #expect(!other.isActive)
  }

  @Test("Missing and stale destinations never mutate the workspace")
  func rejectsInvalidNavigation() async {
    let (repository, workspace, _) = fixture()
    for request in [
      ClientNavigationRequest(workspaceId: workspace.id, destination: .init(kind: .pane, id: UUID())),
      ClientNavigationRequest(workspaceId: UUID(), destination: nil),
    ] {
      let response = await ClientControlConnection.handle(
        .init(requestId: "request", method: "navigate", navigation: request),
        context: { .capture(repository: repository, serverId: "machine", workspaceId: nil, isActive: true) },
        navigate: { repository.save(try $0.applying(to: workspace)) }
      )
      #expect(response.context == nil)
      #expect(response.error != nil)
      #expect(repository.workspace(id: workspace.id) == workspace)
    }
  }
}
