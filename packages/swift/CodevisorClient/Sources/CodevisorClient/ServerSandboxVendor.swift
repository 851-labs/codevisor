import Foundation

public struct ServerSandboxVendor: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var displayName: String
  public var sandboxNoun: String
  public var platform: String
  public var tested: Bool
  public var providerFields: [ServerSandboxField]
  public var profileFields: [ServerSandboxField]

  private enum CodingKeys: String, CodingKey {
    case id, displayName, sandboxNoun, platform, tested, profileFields
    case providerFields = "accountFields"
  }

  public init(
    id: String,
    displayName: String,
    sandboxNoun: String,
    platform: String,
    tested: Bool,
    providerFields: [ServerSandboxField],
    profileFields: [ServerSandboxField]
  ) {
    self.id = id
    self.displayName = displayName
    self.sandboxNoun = sandboxNoun
    self.platform = platform
    self.tested = tested
    self.providerFields = providerFields
    self.profileFields = profileFields
  }
}
