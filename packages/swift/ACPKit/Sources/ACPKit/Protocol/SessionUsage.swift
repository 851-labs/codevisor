import Foundation

/// Cumulative cost information for a session (from a `usage_update`).
public struct SessionCost: Sendable, Codable, Equatable {
  public enum Kind: String, Sendable, Codable, Equatable {
    case reported
    case estimated
  }
  /// Total cumulative cost for the session.
  public var amount: Double
  /// ISO 4217 currency code (e.g. "USD").
  public var currency: String
  public var kind: Kind?

  public init(amount: Double, currency: String, kind: Kind? = nil) {
    self.amount = amount
    self.currency = currency
    self.kind = kind
  }
}

/// Context-window and cost usage for a session (from a `usage_update`).
public struct SessionUsage: Sendable, Codable, Equatable {
  /// Tokens currently in context.
  public var used: UInt64?
  /// Total context-window size in tokens.
  public var size: UInt64?
  public var inputTokens: UInt64?
  public var cachedInputTokens: UInt64?
  public var outputTokens: UInt64?
  public var reasoningOutputTokens: UInt64?
  public var totalTokens: UInt64?
  /// Cumulative session cost, if the agent reports it.
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
