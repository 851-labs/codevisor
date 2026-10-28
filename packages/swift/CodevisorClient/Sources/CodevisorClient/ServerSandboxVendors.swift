import Foundation

public struct ServerSandboxVendors: Decodable, Equatable, Sendable {
  public var vendors: [ServerSandboxVendor]
  public var capabilities: [String]
  public var maximums: [String: [String: Double]]

  private enum CodingKeys: String, CodingKey {
    case capabilities, maximums
    case vendors = "providers"
  }

  public init(
    vendors: [ServerSandboxVendor] = [], capabilities: [String] = [], maximums: [String: [String: Double]] = [:]
  ) {
    self.vendors = vendors
    self.capabilities = capabilities
    self.maximums = maximums
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    vendors = try container.decode([ServerSandboxVendor].self, forKey: .vendors)
    capabilities = try container.decode([String].self, forKey: .capabilities)
    maximums = try container.decodeIfPresent([String: [String: Double]].self, forKey: .maximums) ?? [:]
  }

  public func vendor(_ id: String) -> ServerSandboxVendor? {
    vendors.first { $0.id == id }
  }
}
