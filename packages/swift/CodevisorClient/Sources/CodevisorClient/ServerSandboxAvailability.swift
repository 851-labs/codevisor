import Foundation

public struct ServerSandboxAvailability: Decodable, Equatable, Sendable {
  public var profileId: String
  public var disabledReason: String?
  public var full: Bool?

  public init(profileId: String, disabledReason: String? = nil, full: Bool? = nil) {
    self.profileId = profileId
    self.disabledReason = disabledReason
    self.full = full
  }
}
