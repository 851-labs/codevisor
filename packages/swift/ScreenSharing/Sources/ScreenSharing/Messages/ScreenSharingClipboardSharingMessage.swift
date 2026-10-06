import Foundation

/// Shared clipboard, on the `codevisor.clipboard-sharing.v1` channel. The viewer says whether it
/// wants the host's copies; while it does, the host sends each new copy over the clipboard channel
/// unasked. Copies the other way need no subscription: a host already accepts the viewer's text.
/// A peer that predates the channel never opens it, and only the viewer's copies are shared.
public enum ScreenSharingClipboardSharingMessage: Codable, Sendable, Equatable {
  /// Viewer → host: whether to send the host's clipboard each time it changes.
  case viewer(sharing: Bool)

  public static let maximumBytes = 1024

  public func encoded() throws -> Data {
    let data = try JSONEncoder().encode(Envelope(version: 1, message: self))
    guard data.count <= Self.maximumBytes else {
      throw ScreenSharingError.invalid("Clipboard sharing message is too large.")
    }
    return data
  }

  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes else {
      throw ScreenSharingError.invalid("Clipboard sharing message is too large.")
    }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.version == 1 else { throw ScreenSharingError.invalid("Unsupported clipboard sharing protocol.") }
    return envelope.message
  }

  private struct Envelope: Codable { let version: Int; let message: ScreenSharingClipboardSharingMessage }
}
