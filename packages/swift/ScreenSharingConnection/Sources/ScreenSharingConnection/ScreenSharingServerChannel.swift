import CodevisorClient
import Foundation

@MainActor
public final class ScreenSharingServerChannel: ScreenSharingHostChannel {
  private let client: any CodevisorServerClienting

  public init(client: any CodevisorServerClienting) {
    self.client = client
  }

  public var isReconnecting: Bool { client.isReconnecting }

  public func send(_ request: ServerScreenSharingRequest) async throws -> ServerScreenSharingReply {
    try await client.screenSharing(request)
  }

  public func registerDesktopPane(_ identity: ScreenSharingLegacyIdentity) async throws {
    let pane = ServerWorkspacePane(
      id: identity.paneId.uuidString.lowercased(), workspaceId: identity.workspaceId.uuidString.lowercased(),
      providerId: "codevisor", paneType: ScreenSharingLegacyIdentity.paneType, title: "Desktop",
      createdAt: ServerDateCoding.string(from: Date()))
    _ = try await client.upsertWorkspacePane(pane)
  }
}
