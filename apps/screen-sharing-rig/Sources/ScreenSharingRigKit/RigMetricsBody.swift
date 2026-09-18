import ScreenSharing
import Foundation

public struct RigMetricsBody: Codable, Sendable {
  public let role: String
  public let name: String
  public let build: RigBuildInfo
  public let connection: String
  public let sessionID: String?
  public let capture: String?
  public let snapshot: ScreenSharingMetrics.Snapshot?
  public let statistics: [String: String]
  public let latestSample: RigTelemetrySample?

  public init(
    role: String, name: String, build: RigBuildInfo, connection: String, sessionID: String?, capture: String?,
    snapshot: ScreenSharingMetrics.Snapshot?, statistics: [String: String], latestSample: RigTelemetrySample?
  ) {
    self.role = role
    self.name = name
    self.build = build
    self.connection = connection
    self.sessionID = sessionID
    self.capture = capture
    self.snapshot = snapshot
    self.statistics = statistics
    self.latestSample = latestSample
  }
}
