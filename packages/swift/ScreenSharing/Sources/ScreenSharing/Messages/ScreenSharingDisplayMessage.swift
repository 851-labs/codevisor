import Foundation

/// Dynamic Resolution for native sharing (851-2376), on the `codevisor.display.v1` channel: the
/// host streams a virtual display sized to the viewer's pane (HiDPI, so text is pixel-exact) with
/// its own display mirrored onto it, instead of scaling the physical display. A host that
/// predates the channel never says `ready`, and the viewer's toggle stays unavailable.
public enum ScreenSharingDisplayMessage: Codable, Sendable, Equatable {
  /// Host → viewer: it can size its display to the viewer.
  case ready
  /// Viewer → host: size the display to this many points (the host renders it at 2×).
  case resize(width: Int, height: Int)
  /// Viewer → host: go back to the host's own display at its own size.
  case restore
  /// Host → viewer: the display now has this size, in points.
  case resized(width: Int, height: Int)
  /// Host → viewer: it can't (this Mac, or the request); the message says why.
  case unavailable(String)

  public static let maximumBytes = 1024

  public func encoded() throws -> Data {
    let data = try JSONEncoder().encode(Envelope(version: 1, message: self))
    guard data.count <= Self.maximumBytes else { throw ScreenSharingError.invalid("Display message is too large.") }
    return data
  }

  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes else { throw ScreenSharingError.invalid("Display message is too large.") }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.version == 1 else { throw ScreenSharingError.invalid("Unsupported display protocol.") }
    return envelope.message
  }

  private struct Envelope: Codable { let version: Int; let message: ScreenSharingDisplayMessage }
}
