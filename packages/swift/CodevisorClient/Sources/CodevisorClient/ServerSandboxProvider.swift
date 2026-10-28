import Foundation

public struct ServerSandboxProvider: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var vendor: String
  public var label: String?
  public var identity: String?
  public var values: [String: SandboxFieldValue]
  public var secretsSet: [String]
  public var createdAt: String

  private enum CodingKeys: String, CodingKey {
    case id, label, identity, values, secretsSet, createdAt
    case vendor = "provider"
  }

  public init(
    id: String,
    vendor: String,
    label: String? = nil,
    identity: String? = nil,
    values: [String: SandboxFieldValue] = [:],
    secretsSet: [String] = [],
    createdAt: String = ""
  ) {
    self.id = id
    self.vendor = vendor
    self.label = label
    self.identity = identity
    self.values = values
    self.secretsSet = secretsSet
    self.createdAt = createdAt
  }

  public func title(vendorName: String) -> String {
    guard let detail = identity ?? label else { return vendorName }
    return "\(vendorName) · \(detail)"
  }

  public func machineId(for vendor: ServerSandboxVendor?) -> String? {
    let key = vendor?.providerFields.first { $0.type == .machine }?.key
    return key.flatMap { values[$0]?.stringValue }
  }
}
