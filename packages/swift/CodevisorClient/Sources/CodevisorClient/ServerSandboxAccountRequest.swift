import Foundation

public struct ServerSandboxAccountRequest: Encodable, Equatable, Sendable {
  public var provider: String
  public var label: String?
  public var values: [String: SandboxFieldValue]

  public init(provider: String, label: String?, values: [String: SandboxFieldValue]) {
    self.provider = provider
    self.label = label
    self.values = values
  }
}
