import Foundation

/// A standard VNC server a screen-sharing pane connects to instead of a
/// Codevisor host. The password never lives here: it is in the Keychain,
/// keyed by `credentialAccount`.
public struct ScreenSharingVNCTarget: Codable, Equatable, Hashable, Sendable {
  public static let defaultPort: UInt16 = 5900
  public var host: String
  public var port: UInt16
  public var username: String?

  public init(host: String, port: UInt16 = ScreenSharingVNCTarget.defaultPort, username: String? = nil) {
    self.host = host
    self.port = port
    self.username = username
  }

  /// "host" or "host:port" when the port is not the VNC default.
  public var displayName: String { port == Self.defaultPort ? host : "\(host):\(port)" }
  public var credentialAccount: String { "\(host):\(port)" }
  /// The display id the viewer reducer selects; a VNC target has exactly one.
  public var displayId: String { "vnc:\(host):\(port)" }

  /// The target a display id names, or nil for a machine display.
  public init?(displayId: String) {
    guard displayId.hasPrefix("vnc:"), let separator = displayId.lastIndex(of: ":"),
      let port = UInt16(displayId[displayId.index(after: separator)...])
    else { return nil }
    let host = String(displayId[displayId.index(displayId.startIndex, offsetBy: 4)..<separator])
    guard !host.isEmpty else { return nil }
    self.init(host: host, port: port)
  }
}
