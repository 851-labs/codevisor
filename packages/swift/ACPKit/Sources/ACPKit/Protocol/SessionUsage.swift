import Foundation

public struct SessionCost: Sendable, Codable, Equatable {
  public enum Kind: String, Sendable, Codable, Equatable {
    case reported
    case estimated
  }
  public var amount: Double
  public var currency: String
  public var kind: Kind?

  public init(amount: Double, currency: String, kind: Kind? = nil) {
    self.amount = amount
    self.currency = currency
    self.kind = kind
  }
}

public struct SessionUsage: Sendable, Codable, Equatable {
  public var used: UInt64?
  public var size: UInt64?
  public var inputTokens: UInt64?
  public var cachedInputTokens: UInt64?
  public var outputTokens: UInt64?
  public var reasoningOutputTokens: UInt64?
  public var totalTokens: UInt64?
  public var cost: SessionCost?

  public init(
    used: UInt64? = nil,
    size: UInt64? = nil,
    inputTokens: UInt64? = nil,
    cachedInputTokens: UInt64? = nil,
    outputTokens: UInt64? = nil,
    reasoningOutputTokens: UInt64? = nil,
    totalTokens: UInt64? = nil,
    cost: SessionCost? = nil
  ) {
    self.used = used
    self.size = size
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
    self.reasoningOutputTokens = reasoningOutputTokens
    self.totalTokens = totalTokens
    self.cost = cost
  }
}
