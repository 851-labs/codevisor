import Foundation

/// The pane preferences shared through the registry. Session credentials and SDP never belong here.
public struct ScreenSharingPanePreferences: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var preferredDisplayId: String?

  public init(preferredDisplayId: String? = nil) {
    schemaVersion = 1
    self.preferredDisplayId = preferredDisplayId
  }
}
