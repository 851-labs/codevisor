import Foundation
import ScreenSharingBenchScenes

struct PlayerReport: Encodable {
  let scene: BenchScene
  let seed: UInt64
  let resolution: String
  let display: String
  let displayID: UInt32?
  let canvas: BenchSceneCanvas
  let refreshHz: Int
  let seconds: Double
  let updates: Int
  let versions: Int
  let versionsPerSecond: Double
  let missedRefreshes: Int
  let presentedOnGlass: Int
  let inputEvents: Int
  let cpuPercentOfOneCore: Double
  let hashing: Bool
  let unhashedVersions: Int?

  @MainActor
  init(
    _ configuration: PlayerConfiguration, target: PlayerScreenTarget, measurement: PlayerMeasurement, inputEvents: Int,
    unhashedVersions: Int?
  ) {
    let stats = measurement.stats
    scene = configuration.scene
    seed = configuration.seed
    resolution = target.resolution.rawValue
    display = target.label
    displayID = configuration.displayID
    canvas = target.canvas
    refreshHz = target.refreshHz
    seconds = stats.seconds
    updates = stats.updates
    versions = stats.versions
    versionsPerSecond = stats.seconds > 0 ? Double(stats.versions - 1) / stats.seconds : 0
    missedRefreshes = stats.missedRefreshes
    presentedOnGlass = stats.presentedOnGlass
    self.inputEvents = inputEvents
    cpuPercentOfOneCore = measurement.cpuPercentOfOneCore
    hashing = configuration.hashLog != nil
    self.unhashedVersions = unhashedVersions
  }

  func json() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(self), as: UTF8.self)
  }
}
