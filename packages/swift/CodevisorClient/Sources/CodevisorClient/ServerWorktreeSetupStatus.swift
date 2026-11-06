import Foundation

public struct ServerWorktreeSetupStatus: Decodable, Equatable, Sendable {
  public enum State: String, Decodable, Sendable {
    case running
    case completed
    case failed
  }

  public var worktreeId: String
  public var state: State
  public var worktree: ServerWorktree?
  public var message: String?

  public init(worktreeId: String, state: State, worktree: ServerWorktree? = nil, message: String? = nil) {
    self.worktreeId = worktreeId
    self.state = state
    self.worktree = worktree
    self.message = message
  }

  public static func running(_ worktreeId: String) -> Self {
    Self(worktreeId: worktreeId, state: .running)
  }

  public static func completed(_ worktree: ServerWorktree) -> Self {
    Self(worktreeId: worktree.id, state: .completed, worktree: worktree)
  }

  public static func failed(_ worktreeId: String, message: String) -> Self {
    Self(worktreeId: worktreeId, state: .failed, message: message)
  }
}
