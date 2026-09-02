import CodevisorCore
import Foundation

/// Memoizes the expensive part of navigation ordering: priority/recency
/// sorting. SwiftUI may reevaluate the sidebar while an unrelated composer
/// property changes; rebuilding lightweight keys is cheap, while repeatedly
/// sorting and querying project membership is not. Current value structs are
/// remapped onto the cached ids so row content never goes stale.
@MainActor
final class SidebarOrderingCache {
  static func timestamp(for session: ChatSession, order: SidebarOrder) -> Date {
    switch order {
    case .none, .updated:
      return session.sidebarStateChangedAt
    case .created:
      return session.createdAt
    }
  }

  private struct SessionInput: Equatable {
    let id: SidebarFleetItemID
    let priority: Int
    let timestamp: Date
    let title: String
    let sourceIndex: Int
  }

  private struct ProjectInput: Equatable {
    let id: SidebarFleetItemID
    let priority: Int
    let timestamp: Date
    let name: String
    let sourceIndex: Int
  }

  private var sessionInputs: [SessionInput] = []
  private var orderedSessionIDs: [SidebarFleetItemID] = []
  private var projectInputs: [ProjectInput] = []
  private var orderedProjectIDs: [SidebarFleetItemID] = []

  func sessions(
    _ values: [ChatSession],
    priority: (ChatSession) -> SidebarSessionPriority,
    timestamp: (ChatSession) -> Date
  ) -> [ChatSession] {
    let inputs = values.enumerated().map { index, session in
      SessionInput(
        id: session.sidebarFleetItemID,
        priority: priority(session).rawValue,
        timestamp: timestamp(session),
        title: session.title,
        sourceIndex: index
      )
    }
    if inputs != sessionInputs {
      sessionInputs = inputs
      orderedSessionIDs = inputs.sorted { left, right in
        if left.priority != right.priority { return left.priority < right.priority }
        if left.timestamp != right.timestamp { return left.timestamp > right.timestamp }
        let titleOrder = left.title.localizedCaseInsensitiveCompare(right.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return left.sourceIndex < right.sourceIndex
      }.map(\.id)
    }
    let byID = Dictionary(
      values.map { ($0.sidebarFleetItemID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    return orderedSessionIDs.compactMap { byID[$0] }
  }

  func projects(
    _ values: [Project],
    orderingKey: (Project) -> (priority: SidebarSessionPriority, timestamp: Date)
  ) -> [Project] {
    let inputs = values.enumerated().map { index, project in
      let key = orderingKey(project)
      return ProjectInput(
        id: project.sidebarFleetItemID,
        priority: key.priority.rawValue,
        timestamp: key.timestamp,
        name: project.name,
        sourceIndex: index
      )
    }
    if inputs != projectInputs {
      projectInputs = inputs
      orderedProjectIDs = inputs.sorted { left, right in
        if left.priority != right.priority { return left.priority < right.priority }
        if left.timestamp != right.timestamp { return left.timestamp > right.timestamp }
        let nameOrder = left.name.localizedCaseInsensitiveCompare(right.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return left.sourceIndex < right.sourceIndex
      }.map(\.id)
    }
    let byID = Dictionary(
      values.map { ($0.sidebarFleetItemID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    return orderedProjectIDs.compactMap { byID[$0] }
  }
}
