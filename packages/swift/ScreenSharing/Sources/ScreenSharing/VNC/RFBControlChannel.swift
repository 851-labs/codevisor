import Foundation

public protocol RFBControlChannel: AnyObject, Sendable {
  var onControlText: (@Sendable (String) -> Void)? { get set }
  func sendControlText(_ text: String) async throws
}

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
