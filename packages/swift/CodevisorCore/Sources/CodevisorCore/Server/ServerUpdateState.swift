import Foundation
import Observation

@MainActor
@Observable
final class ServerUpdateState {
  var info: ServerUpdateInfo?
  var restartDrain: ServerRestartDrainState?
  var phase: ServerUpdatePhase = .idle
  var statusMessage: String?
  var progress: Double?
  var dataUpgradeProgress: ServerMigrationProgress?

  func loadRestartDrain(from client: any CodevisorServerClienting) async {
    guard let drain = try? await client.restartDrainState(), !Task.isCancelled else { return }

    restartDrain = drain
  }
}
