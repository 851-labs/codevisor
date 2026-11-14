import Foundation

public struct ScreenSharingProof: Equatable, Sendable {
  public struct Start: Equatable, Sendable {
    public var challenge: ScreenSharingChallenge
    public var appKey: String
    public var viewerId: UUID
    public var intent: ScreenSharingStartIntent
    public var displayId: String?

    public init(
      challenge: ScreenSharingChallenge, appKey: String, viewerId: UUID, intent: ScreenSharingStartIntent,
      displayId: String?
    ) {
      self.challenge = challenge
      self.appKey = appKey
      self.viewerId = viewerId
      self.intent = intent
      self.displayId = displayId
    }
  }

  public static let purpose = "codevisor.screen-sharing.start.v1"

  public let nonce: String
  public let signature: String

  public init(nonce: String, signature: String) {
    self.nonce = nonce
    self.signature = signature
  }

  public init(_ start: Start, signedBy sign: (Data) throws -> Data) rethrows {
    nonce = start.challenge.nonce
    signature = try sign(Self.message(for: start)).map { String(format: "%02x", $0) }.joined()
  }

  public static func message(for start: Start) -> Data {
    let lines = [
      purpose, "start", start.challenge.hostKey.lowercased(), start.challenge.nonce.lowercased(),
      start.appKey.lowercased(), start.viewerId.uuidString.lowercased(), start.intent.rawValue,
      start.displayId ?? "",
    ]
    return Data(lines.joined(separator: "\n").utf8)
  }
}
