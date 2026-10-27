import Foundation

public struct ServerSandboxAccount: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var provider: String
  public var label: String?
  public var identity: String?
  public var values: [String: SandboxFieldValue]
  public var secretsSet: [String]
  public var createdAt: String

  public init(
    id: String,
    provider: String,
    label: String? = nil,
    identity: String? = nil,
    values: [String: SandboxFieldValue] = [:],
    secretsSet: [String] = [],
    createdAt: String = ""
  ) {
    self.id = id
    self.provider = provider
    self.label = label
    self.identity = identity
    self.values = values
    self.secretsSet = secretsSet
    self.createdAt = createdAt
  }

  public func title(providerName: String) -> String {
    guard let detail = identity ?? label else { return providerName }
    return "\(providerName) (\(detail))"
  }
}
