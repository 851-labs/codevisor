@MainActor
public protocol ScreenSharingHostChannel: AnyObject {
  var isReconnecting: Bool { get }
  func send(_ request: ScreenSharingHostRequest) async throws -> ScreenSharingHostReply
  func registerDesktopPane(_ identity: ScreenSharingLegacyIdentity) async throws
}
