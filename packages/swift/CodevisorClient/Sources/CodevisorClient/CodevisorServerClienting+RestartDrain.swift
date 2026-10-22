import Foundation

public extension CodevisorServerClienting {
  func beginRestartDrain() async throws -> ServerRestartDrainState {
    ServerRestartDrainState(state: "drained", remaining: 0)
  }

  func restartDrainState() async throws -> ServerRestartDrainState {
    ServerRestartDrainState(state: "idle", remaining: 0)
  }

  func cancelRestartDrain() async throws {}

  func startUpdateRun(_ request: ServerUpdateRunRequest) async throws -> ServerUpdateRunStarted {
    ServerUpdateRunStarted(run: .idle)
  }

  func updateRunState() async throws -> ServerUpdateRunState {
    .idle
  }

  func cancelUpdateRun() async throws -> ServerUpdateRunState {
    .idle
  }
}
