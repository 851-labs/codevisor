import Foundation

public struct ServerSandboxAvailability: Decodable, Equatable, Sendable {
  public var profileId: String
  public var disabledReason: String?

  public init(profileId: String, disabledReason: String? = nil) {
    self.profileId = profileId
    self.disabledReason = disabledReason
  }
}
