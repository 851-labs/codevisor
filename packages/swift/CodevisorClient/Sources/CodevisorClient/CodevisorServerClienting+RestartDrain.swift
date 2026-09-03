import Foundation

/// Restart-drain defaults for fakes and servers predating the drain: they
/// are treated as already drained, so the caller proceeds to shut down
/// exactly as it did before the drain existed.
public extension CodevisorServerClienting {
  func beginRestartDrain(interrupt: Bool) async throws -> ServerRestartDrainState {
    ServerRestartDrainState(state: "drained", remaining: 0)
  }

  func restartDrainState() async throws -> ServerRestartDrainState {
    ServerRestartDrainState(state: "drained", remaining: 0)
  }

  func cancelRestartDrain() async throws {}
}
