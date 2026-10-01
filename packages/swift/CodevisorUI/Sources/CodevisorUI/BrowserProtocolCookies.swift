import CodevisorClient
import Foundation

/// Decodes Chromium's `Network.getAllCookies` replies for cookie sync. The
/// previous decode is reused while the cookie list's bytes are unchanged, which
/// is the steady state of a profile polled every few seconds.
public struct BrowserProtocolCookies: Sendable {
  private var result: Data?
  private var cookies: [BrowserCookie] = []
  public init() {}

  public mutating func cookies(fromReply reply: Data) throws -> [BrowserCookie] {
    let result = try BrowserProtocolMessage.result(ofReply: reply)
    if result == self.result { return cookies }
    let decoded = try Self.decode(result)
    self.result = result
    cookies = decoded
    return decoded
  }

  /// Partitioned cookies stay local; the shared store has no partition key.
  static func decode(_ result: Data) throws -> [BrowserCookie] {
    let object = try JSONSerialization.jsonObject(with: result) as? [String: Any] ?? [:]
    return (object["cookies"] as? [[String: Any]] ?? []).compactMap { raw in
      guard raw["partitionKey"] == nil, raw["partitionKeyOpaque"] as? Bool != true,
        let name = raw["name"] as? String, let value = raw["value"] as? String,
        let domain = raw["domain"] as? String, let path = raw["path"] as? String
      else { return nil }
      let expiry = raw["expires"] as? Double
      return BrowserCookie(
        name: name, value: value, domain: domain, path: path,
        secure: raw["secure"] as? Bool ?? false, httpOnly: raw["httpOnly"] as? Bool ?? false,
        sameSite: (raw["sameSite"] as? String)?.lowercased() ?? "unspecified",
        expires: expiry.flatMap { $0 > 0 ? $0 : nil })
    }
  }
}
