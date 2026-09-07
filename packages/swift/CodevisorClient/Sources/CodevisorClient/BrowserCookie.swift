import Foundation

public struct BrowserCookie: Codable, Sendable, Equatable {
  public var name: String
  public var value: String
  public var domain: String
  public var path: String
  public var secure: Bool
  public var httpOnly: Bool
  public var sameSite: String
  public var expires: Double?
  public var key: String {
    let fields = [domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased(), path, name]
    return String(
      decoding: try! JSONSerialization.data(withJSONObject: fields, options: [.withoutEscapingSlashes]), as: UTF8.self)
  }
  public init(
    name: String, value: String, domain: String, path: String, secure: Bool, httpOnly: Bool, sameSite: String,
    expires: Double? = nil
  ) {
    self.name = name; self.value = value; self.domain = domain; self.path = path
    self.secure = secure; self.httpOnly = httpOnly; self.sameSite = sameSite; self.expires = expires
  }
}
public struct BrowserCookieMutation: Codable, Sendable {
  public var key: String
  public var expectedRevision: Int
  public var cookie: BrowserCookie?
  public init(key: String, expectedRevision: Int, cookie: BrowserCookie?) {
    self.key = key; self.expectedRevision = expectedRevision; self.cookie = cookie
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(key, forKey: .key)
    try container.encode(expectedRevision, forKey: .expectedRevision)
    try container.encode(cookie, forKey: .cookie)
  }
}
public struct BrowserCookieEntry: Codable, Sendable {
  public var key: String
  public var revision: Int
  public var cookie: BrowserCookie?
  public init(key: String, revision: Int, cookie: BrowserCookie?) {
    self.key = key; self.revision = revision; self.cookie = cookie
  }
}
public struct BrowserCookieSnapshot: Codable, Sendable {
  public var revision: Int
  public var entries: [BrowserCookieEntry]
  public init(revision: Int, entries: [BrowserCookieEntry]) { self.revision = revision; self.entries = entries }
}
public struct BrowserNavigation: Codable, Sendable, Equatable {
  public var url: String
  public var title: String
  public init(url: String, title: String) { self.url = url; self.title = title }
}
