import Foundation

public struct ServerSandboxProfileRequest: Encodable, Equatable, Sendable {
  public var name: String
  public var vendor: String
  public var providerId: String?
  public var values: [String: SandboxFieldValue]

  private enum CodingKeys: String, CodingKey {
    case name, values
    case vendor = "provider"
    case providerId = "accountId"
  }

  public init(name: String, vendor: String, providerId: String?, values: [String: SandboxFieldValue]) {
    self.name = name
    self.vendor = vendor
    self.providerId = providerId
    self.values = values
  }
}
