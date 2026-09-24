import Foundation

/// The lease's side channel next to the RFB bytes (851-2338): codevisor-server
/// arbitrates control of a VNC desktop in text frames on the same WebSocket.
/// A transport that has one (the WebSocket) conforms; TCP doesn't.
public protocol RFBControlChannel: AnyObject, Sendable {
  /// Every text frame the server sends; called from the read loop.
  var onControlText: (@Sendable (String) -> Void)? { get set }
  func sendControlText(_ text: String) async throws
}

/// The server's lease messages, as `VNCHostEmulator` uses them.
enum RFBControlLeaseMessage: Equatable {
  case granted
  case revoked(by: String)

  static func decode(_ text: String) -> Self? {
    guard let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    switch object["type"] as? String {
    case "granted": return .granted
    case "revoked": return .revoked(by: (object["by"] as? String) ?? "Another viewer")
    default: return nil
    }
  }

  static func request(name: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: ["type": "request", "name": name])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? #"{"type":"request"}"#
  }

  static let release = #"{"type":"release"}"#
}
