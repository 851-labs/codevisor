public struct ScreenSharingChallenge: Equatable, Sendable {
  public let hostKey: String
  public let nonce: String

  public init(hostKey: String, nonce: String) {
    self.hostKey = hostKey
    self.nonce = nonce
  }
}
