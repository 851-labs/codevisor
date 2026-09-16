import Foundation

/// Shared presentation preferences. Session credentials and SDP never belong here.
public struct ScreenSharingPanePreferences: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var preferredDisplayId: String?
  public var fitToWindow: Bool

  public init(preferredDisplayId: String? = nil, fitToWindow: Bool = true) {
    schemaVersion = 1
    self.preferredDisplayId = preferredDisplayId
    self.fitToWindow = fitToWindow
  }
}
