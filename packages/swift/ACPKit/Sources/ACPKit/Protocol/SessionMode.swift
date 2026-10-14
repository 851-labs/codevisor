import Foundation

public struct SessionMode: Sendable, Codable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var description: String?
  public var canonicalId: String?

  public init(id: String, name: String, description: String? = nil, canonicalId: String? = nil) {
    self.id = id
    self.name = name
    self.description = description
    self.canonicalId = canonicalId
  }
}

public struct SessionModeState: Sendable, Codable, Equatable {
  public var currentModeId: String
  public var availableModes: [SessionMode]

  public init(currentModeId: String, availableModes: [SessionMode]) {
    self.currentModeId = currentModeId
    self.availableModes = availableModes
  }
}

public enum StopReason: String, Sendable, Codable, Equatable {
  case endTurn = "end_turn"
  case maxTokens = "max_tokens"
  case maxTurnRequests = "max_turn_requests"
  case refusal
  case cancelled
}
