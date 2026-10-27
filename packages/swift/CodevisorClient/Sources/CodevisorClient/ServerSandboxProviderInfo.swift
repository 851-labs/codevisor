import Foundation

public struct ServerSandboxProviderInfo: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var displayName: String
  public var sandboxNoun: String
  public var platform: String
  public var tested: Bool
  public var accountFields: [ServerSandboxField]
  public var profileFields: [ServerSandboxField]

  public init(
    id: String,
    displayName: String,
    sandboxNoun: String,
    platform: String,
    tested: Bool,
    accountFields: [ServerSandboxField],
    profileFields: [ServerSandboxField]
  ) {
    self.id = id
    self.displayName = displayName
    self.sandboxNoun = sandboxNoun
    self.platform = platform
    self.tested = tested
    self.accountFields = accountFields
    self.profileFields = profileFields
  }

  public var usesAccounts: Bool { !accountFields.isEmpty }
}
