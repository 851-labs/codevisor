import Foundation

public enum PlanEntryPriority: String, Sendable, Codable, Equatable {
  case high
  case medium
  case low
}

public enum PlanEntryStatus: String, Sendable, Codable, Equatable {
  case pending
  case inProgress = "in_progress"
  case completed
}

public struct PlanEntry: Sendable, Codable, Equatable {
  public var content: String
  public var priority: PlanEntryPriority
  public var status: PlanEntryStatus

  public init(content: String, priority: PlanEntryPriority, status: PlanEntryStatus) {
    self.content = content
    self.priority = priority
    self.status = status
  }
}

public struct Plan: Sendable, Codable, Equatable {
  public var entries: [PlanEntry]

  public init(entries: [PlanEntry]) {
    self.entries = entries
  }
}

public struct AvailableCommand: Sendable, Codable, Equatable, Identifiable {
  public struct Input: Sendable, Codable, Equatable {
    public var hint: String?

    public init(hint: String? = nil) {
      self.hint = hint
    }
  }

  public var name: String
  public var description: String
  public var input: Input?
  public var id: String { name }

  public init(name: String, description: String, input: Input? = nil) {
    self.name = name
    self.description = description
    self.input = input
  }
}
