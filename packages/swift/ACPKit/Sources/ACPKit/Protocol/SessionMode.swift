import Foundation

/// A session interaction mode.
public struct SessionMode: Sendable, Codable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var description: String?
  /// Codevisor's harness-independent mode id (`readOnly`, `ask`, `autoEdit`,
  /// `fullAccess`, `plan`) when the native mode maps onto one; nil for
  /// agent-defined modes that stay native-only.
  public var canonicalId: String?

  public init(id: String, name: String, description: String? = nil, canonicalId: String? = nil) {
    self.id = id
    self.name = name
    self.description = description
    self.canonicalId = canonicalId
  }
}

/// The set of available modes and the current selection.
public struct SessionModeState: Sendable, Codable, Equatable {
  public var currentModeId: String
  public var availableModes: [SessionMode]

  public init(currentModeId: String, availableModes: [SessionMode]) {
    self.currentModeId = currentModeId
    self.availableModes = availableModes
  }
}

/// The reason a prompt turn ended.
public enum StopReason: String, Sendable, Codable, Equatable {
  case endTurn = "end_turn"
  case maxTokens = "max_tokens"
  case maxTurnRequests = "max_turn_requests"
  case refusal
  case cancelled
}
