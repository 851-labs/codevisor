import Foundation

public struct ServerPluginAccountSpec: Codable, Equatable, Sendable {
  public var label: String
  public var noun: String?
  public var oauth: ServerPluginOAuthSpec?
  public var fields: [ServerConfigField]
  public var guide: ServerPluginAccountGuideSummary?

  public init(
    label: String,
    noun: String? = nil,
    oauth: ServerPluginOAuthSpec? = nil,
    fields: [ServerConfigField] = [],
    guide: ServerPluginAccountGuideSummary? = nil
  ) {
    self.label = label
    self.noun = noun
    self.oauth = oauth
    self.fields = fields
    self.guide = guide
  }

  public var providerName: String? {
    guard let provider = oauth?.provider, let first = provider.first else { return nil }
    return first.uppercased() + provider.dropFirst()
  }

  public var addTitle: String {
    if let guide { return "\(guide.title)…" }
    return providerName.map { "Sign in with \($0)" } ?? "Add \(accountNoun)"
  }

  public var accountNoun: String { (noun ?? "account").capitalized }

  public var accountsTitle: String { "\(accountNoun)s" }

  public var signsInDirectly: Bool {
    oauth != nil && fields.isEmpty
  }
}
