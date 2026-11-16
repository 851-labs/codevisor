import CodevisorClient

@MainActor
public protocol ScreenSharingHostChannel: AnyObject, Sendable {
  var isReconnecting: Bool { get }
  func send(_ request: ServerScreenSharingRequest) async throws -> ServerScreenSharingReply
}
