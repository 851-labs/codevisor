import Foundation

public struct ServerScreenSharingReason: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let stoppedOnHost = Self(rawValue: "stopped-on-host")
  public static let displayAsleep = Self(rawValue: "display-asleep")
  public static let sessionSwitched = Self(rawValue: "session-switched")
  public static let takenOver = Self(rawValue: "taken-over")
  public static let inUse = Self(rawValue: "in-use")
  public static let permissionMissing = Self(rawValue: "permission-missing")
  public static let updateNeeded = Self(rawValue: "update-needed")
  public static let noDisplay = Self(rawValue: "no-display")
}
