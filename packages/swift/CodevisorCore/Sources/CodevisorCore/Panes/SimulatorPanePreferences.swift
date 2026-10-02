import Foundation

/// A Simulator pane's choice of device, shared through the pane registry so
/// every client of the workspace shows the same simulator.
public struct SimulatorPanePreferences: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  /// The simulator the pane shows; nil until one is chosen.
  public var udid: String?

  public init(udid: String? = nil) {
    schemaVersion = 1
    self.udid = udid
  }
}
