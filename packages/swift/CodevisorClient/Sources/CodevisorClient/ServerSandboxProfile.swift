import Foundation

public struct ServerSandboxProfile: Codable, Equatable, Hashable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var provider: String
  public var accountId: String?
  public var values: [String: SandboxFieldValue]
  public var createdAt: String

  public init(
    id: String,
    name: String,
    provider: String,
    accountId: String? = nil,
    values: [String: SandboxFieldValue] = [:],
    createdAt: String = ""
  ) {
    self.id = id
    self.name = name
    self.provider = provider
    self.accountId = accountId
    self.values = values
    self.createdAt = createdAt
  }

  public func machineId(for provider: ServerSandboxProviderInfo?) -> String? {
    let key = provider?.profileFields.first { $0.type == .machine }?.key
    return key.flatMap { values[$0]?.stringValue }
  }
}
