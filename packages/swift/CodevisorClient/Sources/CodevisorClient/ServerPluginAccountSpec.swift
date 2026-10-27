import Foundation

public struct ServerPluginAccountSpec: Codable, Equatable, Sendable {
  public var label: String
  public var oauth: ServerPluginOAuthSpec?
  public var fields: [ServerConfigField]

  public init(label: String, oauth: ServerPluginOAuthSpec? = nil, fields: [ServerConfigField] = []) {
    self.label = label
    self.oauth = oauth
    self.fields = fields
  }

  public var providerName: String? {
    guard let provider = oauth?.provider, let first = provider.first else { return nil }
    return first.uppercased() + provider.dropFirst()
  }

  public var addTitle: String {
    providerName.map { "Sign in with \($0)" } ?? "Add Account"
  }

  public var signsInDirectly: Bool {
    oauth != nil && fields.isEmpty
  }
}
