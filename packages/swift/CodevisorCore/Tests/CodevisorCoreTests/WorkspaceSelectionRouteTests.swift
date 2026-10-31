import Foundation
import Testing

@testable import CodevisorCore

@Suite("Workspace selection route")
struct WorkspaceSelectionRouteTests {
  private func workspace(id: UUID = UUID(), serverId: String = "server-a") -> Workspace {
    Workspace(
      id: id,
      name: "Verification",
      rootDirectory: "/tmp/project",
      serverId: serverId,
      projectId: UUID(),
      centerTree: .leaf(PaneGroupState())
    )
  }

  @Test func anActivatedChatAlwaysWins() {
    let chat = UUID()
    let routing = UUID()
    let space = workspace()

    #expect(
      space.selectionRoute(
        activatedChatSessionId: chat, routingSessionId: routing,
        selectionAlreadyRoutesWorkspace: true
      ) == .session(serverId: space.serverId, id: chat))
  }

  @Test func aChatlessDestinationFallsBackToTheWorkspacesOwnRoutingChat() {
    let routing = UUID()
    let space = workspace()

    #expect(
      space.selectionRoute(
        activatedChatSessionId: nil, routingSessionId: routing,
        selectionAlreadyRoutesWorkspace: false
      ) == .session(serverId: space.serverId, id: routing))
  }

  @Test func anAlreadyRoutedSelectionIsLeftUntouched() {
    let space = workspace()

    #expect(
      space.selectionRoute(
        activatedChatSessionId: nil, routingSessionId: UUID(),
        selectionAlreadyRoutesWorkspace: true
      ) == nil)
  }

  @Test func aChatlessWorkspaceAddressesItself() {
    let id = UUID()
    let space = workspace(id: id, serverId: "stage3v")

    #expect(
      space.selectionRoute(
        activatedChatSessionId: nil, routingSessionId: nil,
        selectionAlreadyRoutesWorkspace: false
      ) == .workspace(serverId: "stage3v", id: id))
  }
}
