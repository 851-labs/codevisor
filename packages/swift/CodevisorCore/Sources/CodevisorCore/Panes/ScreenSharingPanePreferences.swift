import Foundation

/// Shared presentation preferences. Session credentials and SDP never belong here.
public struct ScreenSharingPanePreferences: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var preferredDisplayId: String?
  public var fitToWindow: Bool
  /// A standard VNC server this pane can connect to instead of the machine's
  /// own displays; its display id is `vnc.displayId`. Absent for panes saved
  /// before VNC support, and never carries the password.
  public var vnc: ScreenSharingVNCTarget?

  public init(preferredDisplayId: String? = nil, fitToWindow: Bool = true, vnc: ScreenSharingVNCTarget? = nil) {
    schemaVersion = 1
    self.preferredDisplayId = preferredDisplayId
    self.fitToWindow = fitToWindow
    self.vnc = vnc
  }
}
