import Foundation

public struct SessionAutoResume: Sendable, Equatable {
  public var resumesAt: Date?

  public init(resumesAt: Date? = nil) {
    self.resumesAt = resumesAt
  }
}
