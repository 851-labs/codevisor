import Foundation
import Testing

@testable import CodevisorCore

/// A workspace owns its server identity, project and layout whether or not it
/// has ever hosted a chat. These pin what the sidebar selection becomes when
/// one of its destinations is activated — the decision that previously left a
/// chatless workspace unreachable.
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

  /// The defect: no chat in the destination, none anywhere in the workspace,
  /// and nothing already routed — previously every branch was skipped and the
  /// selection stayed on whatever was showing.
  @Test func aChatlessWorkspaceAddressesItself() {
    let id = UUID()
    let space = workspace(id: id, serverId: "stage3v")

    #expect(
      space.selectionRoute(
        activatedChatSessionId: nil, routingSessionId: nil,
        selectionAlreadyRoutesWorkspace: false
      ) == .workspace(serverId: "stage3v", id: id))
  }

  @Test func theRouteCarriesThisWorkspacesOwnServerIdentity() {
    let first = workspace(serverId: "stage3v")
    let second = workspace(serverId: "local")

    #expect(
      first.selectionRoute(
        activatedChatSessionId: nil, routingSessionId: nil, selectionAlreadyRoutesWorkspace: false)
        == .workspace(serverId: "stage3v", id: first.id))
    #expect(
      second.selectionRoute(
        activatedChatSessionId: nil, routingSessionId: nil, selectionAlreadyRoutesWorkspace: false)
        == .workspace(serverId: "local", id: second.id))
  }

  /// Re-activating a destination in a workspace that is already the selection
  /// is idempotent rather than oscillating with the chat fallback.
  @Test func reactivatingAChatlessWorkspaceIsStable() {
    let space = workspace()
    let first = space.selectionRoute(
      activatedChatSessionId: nil, routingSessionId: nil, selectionAlreadyRoutesWorkspace: false)
    let second = space.selectionRoute(
      activatedChatSessionId: nil, routingSessionId: nil, selectionAlreadyRoutesWorkspace: false)

    #expect(first == second)
  }
}
