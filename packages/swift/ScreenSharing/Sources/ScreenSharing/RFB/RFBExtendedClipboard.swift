import CZlib
import Foundation

/// The Extended Clipboard pseudo-encoding (0xC0A1E5CE), 851-2316: UTF-8
/// clipboard text instead of Latin-1. Its messages ride Server/ClientCutText
/// with a negative length: a u32 of flags (low 16 bits the formats, high bits
/// the action) and the action's payload. Only the text format is used.
///
/// TigerVNC ignores text a client provides unprompted: the client notifies,
/// the server requests (when something on its side pastes), the client
/// provides. The other way, the client requests and the server provides.
public enum RFBExtendedClipboard {
  public static let pseudoEncoding = Int32(bitPattern: 0xC0A1_E5CE)

  public static let text: UInt32 = 1 << 0
  public static let caps: UInt32 = 1 << 24
  public static let request: UInt32 = 1 << 25
  public static let peek: UInt32 = 1 << 26
  public static let notify: UInt32 = 1 << 27
  public static let provide: UInt32 = 1 << 28
  static let actions: UInt32 = caps | request | peek | notify | provide
  /// The largest message (compressed) this client accepts, and the text it offers or takes.
  public static let maximumBytes = 1 << 20

  public enum Message: Sendable, Equatable {
    /// The formats and actions a peer supports, with a maximum size per format (in format order).
    case caps(formats: UInt32, actions: UInt32, maximumSizes: [UInt32])
    case request(formats: UInt32)
    case peek
    case notify(formats: UInt32)
    /// The text, or nil when the provider has none in that format.
    case provide(text: String?)
  }

  public static func encode(_ message: Message) throws -> [UInt8] {
    var writer = RFBByteWriter()
    switch message {
    case .caps(let formats, let actions, let sizes):
      writer.u32(caps | (actions & ~caps & Self.actions) | (formats & 0xFFFF))
      for size in sizes { writer.u32(size) }
    case .request(let formats): writer.u32(request | (formats & 0xFFFF))
    case .peek: writer.u32(peek)
    case .notify(let formats): writer.u32(notify | (formats & 0xFFFF))
    case .provide(let text):
      guard let text else {
        writer.u32(provide)
        return writer.bytes
      }
      writer.u32(provide | Self.text)
      // Text: UTF-8, CRLF line endings, NUL-terminated; the length includes the NUL.
      let bytes =
        Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8) + [0]
      var body = RFBByteWriter()
      body.u32(UInt32(bytes.count))
      body.append(bytes)
      writer.append(try compress(body.bytes))
    }
    return writer.bytes
  }

  public static func decode(_ bytes: [UInt8]) throws -> Message {
    guard bytes.count >= 4 else { throw RFBError.malformed("extended clipboard message of \(bytes.count) bytes") }
    let flags = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    let formats = flags & 0xFFFF
    let payload = Array(bytes.dropFirst(4))
    // In a caps message the other action bits list the actions the peer supports,
    // so caps is checked first; every other message carries exactly one action.
    if flags & caps != 0 {
      let count = formats.nonzeroBitCount
      guard payload.count >= count * 4 else { throw RFBError.malformed("extended clipboard caps without sizes") }
      let sizes = (0..<count).map { index in
        payload[index * 4..<index * 4 + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
      }
      return .caps(formats: formats, actions: flags & actions & ~caps, maximumSizes: sizes)
    }
    switch flags & actions {
    case request: return .request(formats: formats)
    case peek: return .peek
    case notify: return .notify(formats: formats)
    case provide:
      guard formats & text != 0 else { return .provide(text: nil) }
      let inflated = try RFBZlibInflater().inflate(payload)
      // The text format comes first; later formats (rich text, HTML, …) are ignored.
      guard inflated.count >= 4 else { throw RFBError.malformed("extended clipboard provide without a length") }
      let length = Int(inflated[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
      guard length <= inflated.count - 4, length <= maximumBytes else {
        throw RFBError.malformed("extended clipboard text of \(length) bytes")
      }
      var textBytes = Array(inflated[4..<4 + length])
      if textBytes.last == 0 { textBytes.removeLast() }
      guard let text = String(bytes: textBytes, encoding: .utf8) else {
        throw RFBError.malformed("extended clipboard text isn't UTF-8")
      }
      return .provide(text: text.replacingOccurrences(of: "\r\n", with: "\n"))
    default:
      throw RFBError.malformed("extended clipboard action \(String(flags >> 24, radix: 2))")
    }
  }

  /// One complete zlib stream (a fresh stream per message, as the extension requires).
  static func compress(_ bytes: [UInt8]) throws -> [UInt8] {
    var length = compressBound(uLong(bytes.count))
    var output = [UInt8](repeating: 0, count: Int(length))
    let status = output.withUnsafeMutableBufferPointer { destination in
      bytes.withUnsafeBufferPointer { source in
        compress2(destination.baseAddress, &length, source.baseAddress, uLong(source.count), Z_DEFAULT_COMPRESSION)
      }
    }
    guard status == Z_OK else { throw RFBError.malformed("zlib error \(status)") }
    return Array(output.prefix(Int(length)))
  }
}
