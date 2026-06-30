import Foundation

/// The priority of a plan entry.
public enum PlanEntryPriority: String, Sendable, Codable, Equatable, CaseIterable {
    case high
    case medium
    case low
}

/// The status of a plan entry.
public enum PlanEntryStatus: String, Sendable, Codable, Equatable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case completed
}

/// A single entry in an agent execution plan.
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

/// An agent execution plan.
public struct Plan: Sendable, Codable, Equatable {
    public var entries: [PlanEntry]

    public init(entries: [PlanEntry]) {
        self.entries = entries
    }
}

/// A slash command advertised by the agent.
public struct AvailableCommand: Sendable, Codable, Equatable, Identifiable {
    public var name: String
    public var description: String
    public var id: String { name }

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}
