import Foundation

public struct ServerScreenSharingChallenge: Codable, Sendable, Equatable {
  public let hostKey: String
  public let nonce: String

  public init(hostKey: String, nonce: String) {
    self.hostKey = hostKey
    self.nonce = nonce
  }
}
