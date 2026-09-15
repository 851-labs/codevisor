import CodevisorScreenSharing
import Foundation

public struct RigStatus: Codable, Equatable, Sendable {
  public let role: String
  public let name: String
  public let build: RigBuildInfo
  public let connection: String
  public let sessionID: String?
  public let peerName: String?
  public let peerBuild: RigBuildInfo?
  public let uptimeSeconds: Double
  public let reconnects: Int
  public let capture: String?
  public let hud: Bool

  public init(
    role: String, name: String, build: RigBuildInfo, connection: String, sessionID: String?, peerName: String?,
    peerBuild: RigBuildInfo?, uptimeSeconds: Double, reconnects: Int, capture: String?, hud: Bool
  ) {
    self.role = role
    self.name = name
    self.build = build
    self.connection = connection
    self.sessionID = sessionID
    self.peerName = peerName
    self.peerBuild = peerBuild
    self.uptimeSeconds = uptimeSeconds
    self.reconnects = reconnects
    self.capture = capture
    self.hud = hud
  }
}

public struct RigErrorBody: Codable, Equatable, Sendable {
  public let error: String
  public init(error: String) { self.error = error }
}

public struct RigSampleRequest: Codable, Equatable, Sendable {
  public let seconds: Int
  public let report: String
  public init(seconds: Int, report: String) {
    self.seconds = seconds
    self.report = report
  }
}

public struct RigSampleResponse: Codable, Equatable, Sendable {
  public let report: String
  public let samples: Int
  public let meanPresentedFramesPerSecond: Double?
  public init(report: String, samples: Int, meanPresentedFramesPerSecond: Double?) {
    self.report = report
    self.samples = samples
    self.meanPresentedFramesPerSecond = meanPresentedFramesPerSecond
  }
}

public struct RigHUDRequest: Codable, Equatable, Sendable {
  public let enabled: Bool
  public init(enabled: Bool) { self.enabled = enabled }
}
