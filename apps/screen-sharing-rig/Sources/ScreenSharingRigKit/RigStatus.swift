import ScreenSharing
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
  /// Active engine tuning label; nil for product defaults.
  public let tuning: String?

  public init(
    role: String, name: String, build: RigBuildInfo, connection: String, sessionID: String?, peerName: String?,
    peerBuild: RigBuildInfo?, uptimeSeconds: Double, reconnects: Int, capture: String?, hud: Bool,
    tuning: String? = nil
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
    self.tuning = tuning
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

/// Host control: replace the capture source, live if a session exists.
public struct RigSourceRequest: Codable, Equatable, Sendable {
  public let capture: String
  public init(capture: String) { self.capture = capture }
}

public struct RigSourceResponse: Codable, Equatable, Sendable {
  public let capture: String
  public let previous: String
  public let live: Bool
  public init(capture: String, previous: String, live: Bool) {
    self.capture = capture
    self.previous = previous
    self.live = live
  }
}

/// Host clock responder: both values from the host's `CACurrentMediaTime` clock.
public struct RigClockReply: Codable, Equatable, Sendable {
  public let receivedAtSeconds: Double
  public let sentAtSeconds: Double
  public init(receivedAtSeconds: Double, sentAtSeconds: Double) {
    self.receivedAtSeconds = receivedAtSeconds
    self.sentAtSeconds = sentAtSeconds
  }
}
