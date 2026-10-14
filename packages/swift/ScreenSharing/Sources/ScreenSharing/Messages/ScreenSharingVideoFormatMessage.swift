import Foundation

public enum ScreenSharingVideoFormatMessage: Codable, Sendable, Equatable {
  case viewer(highDynamicRange: Bool)
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
