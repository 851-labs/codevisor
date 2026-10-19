import Foundation

public enum ScreenSharingClipboardMessage: Codable, Sendable, Equatable {
  case read(id: UUID)
  case begin(id: UUID, bytes: Int, richContent: Bool? = nil)
  case chunk(id: UUID, index: Int, data: Data)
  case ack(id: UUID, nextIndex: Int)
  case end(id: UUID)
  case result(id: UUID, error: String?)
  case cancel(id: UUID)

  public static let maximumTextBytes = 64 * 1024
  public static let maximumContentBytes = 32 * 1024 * 1024
  public static let chunkBytes = 2048
  public static let richChunkBytes = 48 * 1024
  public static let richWindow = 8
  public static let maximumBytes = 80 * 1024
  public var id: UUID {
    switch self {
    case .read(let id), .begin(let id, _, _), .chunk(let id, _, _), .ack(let id, _), .end(let id),
      .result(let id, _), .cancel(let id):
      id
    }
  }
  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let data = try encoder.encode(Envelope(version: 1, message: self))
    guard data.count <= Self.maximumBytes else { throw ScreenSharingError.invalid("Clipboard message is too large.") }
    return data
  }
  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes else { throw ScreenSharingError.invalid("Clipboard message is too large.") }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.version == 1 else { throw ScreenSharingError.invalid("Unsupported clipboard protocol.") }
    return envelope.message
  }
  private struct Envelope: Codable { let version: Int; let message: ScreenSharingClipboardMessage }
}
