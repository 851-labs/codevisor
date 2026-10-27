import Foundation

public struct ServerSandboxProviderRequest: Encodable, Equatable, Sendable {
  public var vendor: String
  public var label: String?
  public var values: [String: SandboxFieldValue]

  private enum CodingKeys: String, CodingKey {
    case label, values
    case vendor = "provider"
  }

  public init(vendor: String, label: String?, values: [String: SandboxFieldValue]) {
    self.vendor = vendor
    self.label = label
    self.values = values
  }
}
