import Foundation

public struct ServerPluginCatalogSignIn: Codable, Equatable, Sendable {
  public enum OAuth: String, Codable, Sendable {
    case none
    case optional
    case required
  }

  public var oauth: OAuth

  public init(oauth: OAuth) {
    self.oauth = oauth
  }
}
