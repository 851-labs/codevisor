import CodevisorClient

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

}
