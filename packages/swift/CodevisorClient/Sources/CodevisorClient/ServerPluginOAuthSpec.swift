import Foundation

public struct ServerPluginOAuthSpec: Codable, Equatable, Sendable {
  public var provider: String
  public var scopes: [String]
  public var client: String?
  public var setupUrl: String?

  public init(provider: String, scopes: [String] = [], client: String? = nil, setupUrl: String? = nil) {
    self.provider = provider
    self.scopes = scopes
    self.client = client
    self.setupUrl = setupUrl
  }
}
