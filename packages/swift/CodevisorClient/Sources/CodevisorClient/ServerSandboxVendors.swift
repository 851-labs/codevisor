import Foundation

public struct ServerSandboxVendors: Decodable, Equatable, Sendable {
  public var vendors: [ServerSandboxVendor]
  public var capabilities: [String]

  private enum CodingKeys: String, CodingKey {
    case capabilities
    case vendors = "providers"
  }

  public init(vendors: [ServerSandboxVendor] = [], capabilities: [String] = []) {
    self.vendors = vendors
    self.capabilities = capabilities
  }

  public func vendor(_ id: String) -> ServerSandboxVendor? {
    vendors.first { $0.id == id }
  }
}
