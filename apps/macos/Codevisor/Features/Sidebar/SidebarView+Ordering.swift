import CodevisorCore
import SwiftUI

/// Sorting and manual-order behavior lives outside the primary view file so
/// sidebar fixes do not grow its grandfathered structural-lint violations.
extension SidebarView {
  func archiveChat(_ session: ChatSession) {
    let archivedWorkspace = environment.archiveSessionAndWorkspaceIfEmpty(session)
    if selection == .session(serverId: session.serverId, id: session.id) {
      selectNextChat(excluding: [session.id], serverId: session.serverId)
    }
    if archivedWorkspace {
      workspaceRevision += 1
    }
  }

  func sortedProjects(_ projects: [Project]) -> [Project] {
    projects.sorted(by: compareProjects)
  }

  func compareProjects(_ left: Project, _ right: Project) -> Bool {
    if order == .updated {
      let leftPriority = projectPriority(for: left)
      let rightPriority = projectPriority(for: right)
      if leftPriority != rightPriority {
        return leftPriority.rawValue < rightPriority.rawValue
      }
    }
    let leftTimestamp = projectTimestamp(for: left)
    let rightTimestamp = projectTimestamp(for: right)
    if leftTimestamp != rightTimestamp {
      return leftTimestamp > rightTimestamp
    }
    return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
  }

  func compareSessions(_ left: ChatSession, _ right: ChatSession) -> Bool {
    if order == .updated {
      let leftPriority = sessionPriority(for: left)
      let rightPriority = sessionPriority(for: right)
      if leftPriority != rightPriority {
        return leftPriority.rawValue < rightPriority.rawValue
      }
    }
    let leftTimestamp = SidebarOrderingCache.timestamp(for: left, order: order)
    let rightTimestamp = SidebarOrderingCache.timestamp(for: right, order: order)
    if leftTimestamp != rightTimestamp {
      return leftTimestamp > rightTimestamp
    }
    return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
  }

  func projectPriority(for project: Project) -> SidebarSessionPriority {
    projectOrderingKey(for: project).priority
  }

  /// Classifies a session into its sort tier. The checks MUST mirror
  /// `ChatSessionLeadingIcon`'s precedence (error → waiting → in progress →
  /// unread): a mid-run agent with buffered unread turns shows the spinner,
  /// not the badge, so it must sort as in progress too. Classifying it as
  /// unread made opening it silently drop it a tier — the row slid down on
  /// click with no visible state change. Rank order across tiers is
  /// `SidebarSessionPriority`; only classification follows the icon.
  func sessionPriority(for session: ChatSession) -> SidebarSessionPriority {
    if store?.hasUnreadError(session) == true { return .errored }
    if store?.isWaitingOnUser(session) == true { return .waitingForUser }
    if store?.isInProgress(session) == true { return .inProgress }
    if unreadCount(for: session) != nil { return .unread }
    return .idle
  }

  /// The unread-turn count for a session's badge; nil when there is nothing
  /// to badge so the row falls through to the relative timestamp.
  func unreadCount(for session: ChatSession) -> Int? {
    guard let count = store?.unreadCount(session), count > 0 else { return nil }
    return count
  }

  /// Whether the row is currently badged as unread, by either count or error.
  func isUnread(_ session: ChatSession) -> Bool {
    unreadCount(for: session) != nil || store?.hasUnreadError(session) == true
  }

  func projectTimestamp(for project: Project) -> Date {
    switch order {
    case .none, .created:
      return project.createdAt
    case .updated:
      return projectOrderingKey(for: project).timestamp
    }
  }

  /// Computes the project tier and its recency in one pass. The old pair of
  /// helpers each fetched and sorted the same project sessions, multiplying
  /// work during every SwiftUI sidebar evaluation.
  func projectOrderingKey(
    for project: Project
  ) -> (priority: SidebarSessionPriority, timestamp: Date) {
    guard order == .updated else { return (.idle, project.createdAt) }
    var leadingPriority: SidebarSessionPriority?
    var leadingTimestamp = project.createdAt
    for session in list.sessions
    where
      session.serverId == project.serverId
      && session.projectId == project.id
      && !session.isArchived
      && (session.origin == .codevisor || list.showsImportedSessions)
    {
      let priority = sessionPriority(for: session)
      guard let currentPriority = leadingPriority else {
        leadingPriority = priority
        leadingTimestamp = session.sidebarStateChangedAt
        continue
      }
      if priority.rawValue < currentPriority.rawValue {
        leadingPriority = priority
        leadingTimestamp = session.sidebarStateChangedAt
      } else if priority == currentPriority,
        session.sidebarStateChangedAt > leadingTimestamp
      {
        leadingTimestamp = session.sidebarStateChangedAt
      }
    }
    return (leadingPriority ?? .idle, leadingTimestamp)
  }

  func setOrder(_ newOrder: SidebarOrder) {
    guard newOrder != order else { return }
    if newOrder == .none {
      seedManualOrdersIfNeeded()
    }
    orderRaw = newOrder.rawValue
  }

  func seedManualOrdersIfNeeded() {
    if projectOrder.isEmpty {
      saveProjectOrder(sortedProjects(list.activeProjects).map(\.id))
    }
    if sessionOrder.isEmpty {
      let sessions = list.activeProjects.flatMap { list.sessions(in: $0) }
      saveSessionOrder(sessions.sorted(by: compareSessions).map(\.id))
    }
  }

  func resetManualOrder() {
    let sessions = list.activeProjects.flatMap { list.sessions(in: $0) }
    saveSessionOrder(
      sessions.sorted { left, right in
        let leftTimestamp = left.sidebarStateChangedAt
        let rightTimestamp = right.sidebarStateChangedAt
        if leftTimestamp != rightTimestamp { return leftTimestamp > rightTimestamp }
        return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
      }.map(\.id))
  }

  /// Reorders whole groups (identified by their primary record) and
  /// persists the flattened member order, so every machine's record of a
  /// linked project travels together and the group stays contiguous.
  func moveProject(_ sourceID: UUID, before destinationID: UUID) {
    guard sourceID != destinationID else { return }
    var groups = visibleProjectGroups
    guard let sourceIndex = groups.firstIndex(where: { $0.primary.id == sourceID }),
      let destinationIndex = groups.firstIndex(where: { $0.primary.id == destinationID })
    else { return }
    withAnimation(.snappy(duration: 0.22)) {
      let moved = groups.remove(at: sourceIndex)
      groups.insert(moved, at: destinationIndex)
      saveProjectOrder(groups.flatMap { $0.members.map(\.id) })
    }
  }

  func saveProjectOrder(_ ids: [UUID]) {
    manualProjectOrderRaw = ids.map(\.uuidString).joined(separator: "\n")
  }

  func moveSession(_ sourceID: UUID, before destinationID: UUID) {
    guard sourceID != destinationID else { return }
    let sessions = list.activeProjects.flatMap { list.sessions(in: $0) }
    var ids = manuallyOrderedSessions(sessions, session: \.self).map(\.id)
    guard let sourceIndex = ids.firstIndex(of: sourceID),
      let destinationIndex = ids.firstIndex(of: destinationID)
    else { return }
    withAnimation(.snappy(duration: 0.22)) {
      let moved = ids.remove(at: sourceIndex)
      ids.insert(moved, at: destinationIndex)
      saveSessionOrder(ids)
    }
  }

  func saveSessionOrder(_ ids: [UUID]) {
    manualSessionOrderRaw = ids.map(\.uuidString).joined(separator: "\n")
  }

  /// Applies persisted session ranks while placing chats that do not have a
  /// saved rank yet at the top. New chats are ordered newest-first until the
  /// next manual move persists their positions.
  func manuallyOrderedSessions<Value>(
    _ values: [Value],
    session: KeyPath<Value, ChatSession>
  ) -> [Value] {
    let ranks = Dictionary(uniqueKeysWithValues: sessionOrder.enumerated().map { ($0.element, $0.offset) })
    return values.enumerated().sorted { left, right in
      let leftSession = left.element[keyPath: session]
      let rightSession = right.element[keyPath: session]
      let leftRank = ranks[leftSession.id]
      let rightRank = ranks[rightSession.id]
      switch (leftRank, rightRank) {
      case let (leftRank?, rightRank?): return leftRank < rightRank
      case (_?, nil): return false
      case (nil, _?): return true
      case (nil, nil):
        if leftSession.createdAt != rightSession.createdAt {
          return leftSession.createdAt > rightSession.createdAt
        }
        return left.offset < right.offset
      }
    }.map(\.element)
  }

  /// Applies persisted ranks while keeping newly-created projects in the
  /// source's stable order at the end until the next manual move.
  func manuallyOrdered<Value>(
    _ values: [Value],
    ids: [UUID],
    id: KeyPath<Value, UUID>
  ) -> [Value] {
    let ranks = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
    return values.enumerated().sorted { left, right in
      let leftRank = ranks[left.element[keyPath: id]]
      let rightRank = ranks[right.element[keyPath: id]]
      switch (leftRank, rightRank) {
      case let (leftRank?, rightRank?): return leftRank < rightRank
      case (_?, nil): return true
      case (nil, _?): return false
      case (nil, nil): return left.offset < right.offset
      }
    }.map(\.element)
  }
}
