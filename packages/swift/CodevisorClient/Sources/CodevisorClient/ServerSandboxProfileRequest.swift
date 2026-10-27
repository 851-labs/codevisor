import Foundation

public struct ServerSandboxProfileRequest: Encodable, Equatable, Sendable {
  public var name: String
  public var provider: String
  public var accountId: String?
  public var values: [String: SandboxFieldValue]

  public init(name: String, provider: String, accountId: String?, values: [String: SandboxFieldValue]) {
    self.name = name
    self.provider = provider
    self.accountId = accountId
    self.values = values
  }
}
