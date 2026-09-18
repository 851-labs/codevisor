import ScreenSharing
import ScreenSharingWebRTC
import Foundation

public struct RigOfferRequest: Codable, Sendable {
  public let version: Int
  public let sessionID: String
  public let offer: ScreenSharingDescription
  public let build: RigBuildInfo
  public let name: String

  public init(sessionID: String, offer: ScreenSharingDescription, build: RigBuildInfo, name: String) {
    version = 1
    self.sessionID = sessionID
    self.offer = offer
    self.build = build
    self.name = name
  }
}

/// Host → viewer: the answer for that session.
public struct RigAnswerResponse: Codable, Sendable {
  public let version: Int
  public let sessionID: String
  public let answer: ScreenSharingDescription
  public let build: RigBuildInfo
  public let name: String

  public init(sessionID: String, answer: ScreenSharingDescription, build: RigBuildInfo, name: String) {
    version = 1
    self.sessionID = sessionID
    self.answer = answer
    self.build = build
    self.name = name
  }
}
