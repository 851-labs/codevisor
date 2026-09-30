import Foundation

/// HDR for native sharing (851-2380), on the `codevisor.video-format.v1` channel. The viewer says
/// whether its display can show high dynamic range; the host then captures and encodes 10-bit
/// Display P3 PQ when its own display has headroom too, and says what it sends. A peer that
/// predates the channel never opens it, and the stream stays 8-bit SDR.
public enum ScreenSharingVideoFormatMessage: Codable, Sendable, Equatable {
  /// Viewer → host: whether the display the viewer is on can show HDR (sent again when it moves).
  case viewer(highDynamicRange: Bool)
  /// Host → viewer: the dynamic range it now sends, and why it isn't HDR when the viewer can show it.
  case sending(ScreenSharingDynamicRange, reason: String?)

  public static let maximumBytes = 1024

  public func encoded() throws -> Data {
    let data = try JSONEncoder().encode(Envelope(version: 1, message: self))
    guard data.count <= Self.maximumBytes else {
      throw ScreenSharingError.invalid("Video format message is too large.")
    }
    return data
  }

  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes else { throw ScreenSharingError.invalid("Video format message is too large.") }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.version == 1 else { throw ScreenSharingError.invalid("Unsupported video format protocol.") }
    return envelope.message
  }

  private struct Envelope: Codable { let version: Int; let message: ScreenSharingVideoFormatMessage }
}
