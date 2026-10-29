import Foundation

public struct BenchRun: Codable, Sendable, Equatable {
  public var id: String
  public var tier: Int
  public var startedAt: Date
  public var gitSha: String
  public var trigger: String

  public init(id: String, tier: Int, startedAt: Date, gitSha: String, trigger: String) {
    self.id = id
    self.tier = tier
    self.startedAt = startedAt
    self.gitSha = gitSha
    self.trigger = trigger
  }
}
