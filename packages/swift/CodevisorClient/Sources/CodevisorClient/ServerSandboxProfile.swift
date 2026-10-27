import Foundation

public struct ServerSandboxProfile: Codable, Equatable, Hashable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var vendor: String
  public var providerId: String?
  public var values: [String: SandboxFieldValue]
  public var createdAt: String

  private enum CodingKeys: String, CodingKey {
    case id, name, values, createdAt
    case vendor = "provider"
    case providerId = "accountId"
  }

  public init(
    id: String,
    name: String,
    vendor: String,
    providerId: String? = nil,
    values: [String: SandboxFieldValue] = [:],
    createdAt: String = ""
  ) {
    self.id = id
    self.name = name
    self.vendor = vendor
    self.providerId = providerId
    self.values = values
    self.createdAt = createdAt
  }

  public func machineId(vendor: ServerSandboxVendor?, provider: ServerSandboxProvider?) -> String? {
    if let machineId = provider?.machineId(for: vendor) { return machineId }
    let key = vendor?.profileFields.first { $0.type == .machine }?.key
    return key.flatMap { values[$0]?.stringValue }
  }
}
