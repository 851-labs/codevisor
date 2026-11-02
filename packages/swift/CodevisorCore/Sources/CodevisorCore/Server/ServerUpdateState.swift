import Foundation
import Observation

public enum ServerUpdatePhase: Equatable, Sendable {
  case idle
  case updating
  case failed(String)
}

@MainActor
@Observable
final class ServerUpdateState {
  var info: ServerUpdateInfo?
  var restartDrain: ServerRestartDrainState?
  var updateRun: ServerUpdateRunState?
  var phase: ServerUpdatePhase = .idle
  var statusMessage: String?
  var progress: Double?
  var dataUpgradeProgress: ServerMigrationProgress?
  var stages: ServerUpdateStages?

  var activity: ServerUpdateActivity? {
    guard let stages else { return nil }

    return ServerUpdateActivity(
      stages: stages,
      statusMessage: statusMessage,
      progress: progress,
      migration: dataUpgradeProgress
    )
  }

  func advance(to stage: ServerUpdateStage) {
    guard stages != nil else {
      stages = ServerUpdateStages(stage)
      return
    }

    stages?.advance(to: stage)
  }

  func loadRestartDrain(from client: any CodevisorServerClienting) async {
    guard let drain = try? await client.restartDrainState(), !Task.isCancelled else { return }

    restartDrain = drain
  }

  func loadUpdateRun(from client: any CodevisorServerClienting) async {
    guard let run = try? await client.updateRunState(), !Task.isCancelled else { return }

    updateRun = run
  }
}
