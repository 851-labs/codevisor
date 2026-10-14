import Foundation

public struct SimulatorPanePreferences: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var udid: String?

  public init(udid: String? = nil) {
    schemaVersion = 1
    self.udid = udid
  }
}
