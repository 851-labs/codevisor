import Foundation

public struct ServerPluginAccountOAuthRequest: Encodable, Equatable, Sendable {
  public var values: [String: ServerConfigFieldValue]
  public var label: String?
  public var accountId: String?

  public init(values: [String: ServerConfigFieldValue] = [:], label: String? = nil, accountId: String? = nil) {
    self.values = values
    self.label = label
    self.accountId = accountId
  }
}
