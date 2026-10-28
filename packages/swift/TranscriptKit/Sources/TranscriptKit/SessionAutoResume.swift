import Foundation

public struct SessionAutoResume: Sendable, Equatable {
  public enum State: String, Sendable, Equatable {
    case scheduled
    case resuming
    case failed
  }

  public var state: State
  public var resumesAt: Date?

  public init(state: State = .scheduled, resumesAt: Date? = nil) {
    self.state = state
    self.resumesAt = resumesAt
  }
}
