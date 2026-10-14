import Foundation

public extension CodevisorServerClienting {
  func beginRestartDrain(interrupt: Bool) async throws -> ServerRestartDrainState {
    ServerRestartDrainState(state: "drained", remaining: 0)
  }

  func restartDrainState() async throws -> ServerRestartDrainState {
    ServerRestartDrainState(state: "drained", remaining: 0)
  }

  func cancelRestartDrain() async throws {}
}
