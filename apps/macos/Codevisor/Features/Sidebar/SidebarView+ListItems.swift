import SwiftUI
import UniformTypeIdentifiers
import CodevisorCore
import CodevisorTheming
import os
import CodevisorUI

extension SidebarView {
  var projectOrder: [UUID] {
    manualProjectOrderRaw
      .split(separator: "\n")
      .compactMap { UUID(uuidString: String($0)) }
  }

  var sessionOrder: [UUID] {
    manualSessionOrderRaw
      .split(separator: "\n")
      .compactMap { UUID(uuidString: String($0)) }
  }

  /// Cached rows can briefly outlive a removed or newly-canonicalized
  /// machine identity. They remain useful for offline live machines, but an
  /// identity absent from the current fleet must never become a route.
  private var canonicalFleetProjects: [Project] {
    list.fleetActiveProjects.filter {
      environment.machines.machine(for: $0.serverId) != nil
    }
  }

  var visibleProjects: [Project] {
    let active = canonicalFleetProjects
    if order == .none {
      return manuallyOrdered(active, ids: projectOrder, id: \.id)
    }
    return deferredProjectOrder.applying(
      to: automaticallySortedProjects,
      id: \.sidebarFleetOrderID
    )
  }

  private var automaticallySortedProjects: [Project] {
    orderingCache.projects(
      canonicalFleetProjects,
      orderingKey: projectOrderingKey
    )
  }

  private var automaticallySortedSessions: [ChatSession] {
    // Flattened fleet: (serverId, projectId) pairs scope membership, so
    // one machine's project can never claim another machine's chats.
    let activeProjectKeys = Set(canonicalFleetProjects.map { "\($0.serverId)|\($0.id)" })
    // The cache applies the final global order, so sourcing sessions via
    // `sessions(in:)` would first perform a throwaway per-project sort.
    // Filter the model's value array once instead.
    let sessions = list.sessions.filter { session in
      activeProjectKeys.contains("\(session.serverId)|\(session.projectId)")
        && !session.isArchived
        && (session.origin == .codevisor || list.showsImportedSessions)
    }
    return orderingCache.sessions(
      sessions,
      priority: { order == .updated ? sessionPriority(for: $0) : .idle },
      timestamp: { SidebarOrderingCache.timestamp(for: $0, order: order) }
    )
  }

  /// Projects shown as folders in "by project": scratch backing projects
  /// (the single-use folder behind a no-project chat) are not projects —
  /// their chats render at the list root instead.
  var projectSectionProjects: [Project] {
    visibleProjects.filter { project in
      !project.isScratch
        && (showEmptyProjects || !list.fleetSessions(in: project).isEmpty)
    }
  }

  /// Match iOS by placing scratch-backed chats at the root and keeping
  /// workspace containers out of the "by project" organization.
  var looseProjectSessions: [SidebarSessionListItem] {
    chronologicalSessions.filter(\.project.isScratch)
  }

  var chronologicalSessions: [SidebarSessionListItem] {
    if order != .none {
      let projectsByKey = Dictionary(
        visibleProjects.map { ("\($0.serverId)|\($0.id)", $0) },
        uniquingKeysWith: { first, _ in first }
      )
      let sorted = automaticallySortedSessions.compactMap { session -> SidebarSessionListItem? in
        guard let project = projectsByKey["\(session.serverId)|\(session.projectId)"]
        else { return nil }
        return SidebarSessionListItem(session: session, project: project)
      }
      return deferredSessionOrder.applying(to: sorted, id: \.orderingID)
    }
    let sessions = visibleProjects.flatMap { project in
      list.fleetSessions(in: project).map {
        SidebarSessionListItem(session: $0, project: project)
      }
    }
    return manuallyOrderedSessions(sessions, session: \.session)
  }

  /// The identity order the automatic sort wants right now, ignoring the
  /// hover and settle holds. Watched to coalesce bursts of reorders into a
  /// single reflow; empty under manual ordering, which never auto-reorders.
  var desiredAutomaticOrderIDs: [String] {
    guard order != .none else { return [] }
    let projectIDs = automaticallySortedProjects.map(\.sidebarFleetOrderID)
    let sessionIDs = automaticallySortedSessions.map(\.sidebarFleetOrderID)
    return projectIDs + sessionIDs
  }

  /// "By workspace": workspaces with visible agents, plus empty workspaces
  /// when requested. Groups follow the chronological agent list, with empty
  /// workspaces last by creation date.
  var workspaceItems: [SidebarWorkspaceListItem] {
    _ = workspaceRevision
    _ = environment.workspaceSync.revision
    // Nous renders each workspace's tabs; the mounted container reports
    // its tab writes (⌘T/⌘W/⌘1-9) through the store since the
    // repository itself is not observable.
    _ = store?.workspaceLayoutRevision
    let sessionItems = chronologicalSessions
    let sessionRank = Dictionary(
      sessionItems.enumerated().map { ($0.element.id, $0.offset) },
      uniquingKeysWith: min
    )
    let sessionsById = Dictionary(
      sessionItems.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let workspaces = environment.workspaces.loadAll().filter {
      !$0.isArchived && environment.machines.machine(for: $0.serverId) != nil
    }
    return
      workspaces
      .compactMap { workspace -> (item: SidebarWorkspaceListItem, rank: Int, created: Date)? in
        let routedSessionIDs = workspace.chatSessionIds.filter {
          environment.workspaces.workspaceId(forSession: $0) == workspace.id
        }
        // Suppress superseded automatic workspaces whose agents moved
        // to another group; they are stale records, not empty groups.
        guard workspace.chatSessionIds.isEmpty || !routedSessionIDs.isEmpty else {
          return nil
        }
        let workspaceSessionItems = routedSessionIDs.compactMap {
          sessionsById[.session(serverId: workspace.serverId, id: $0)]
        }
        let workspaceSessions = workspaceSessionItems.map(\.session)
        let primary = workspaceSessionItems.first
        // A legacy or draft CHAT-LESS workspace stays openable
        // through any session still routed to it by the grow-only
        // session index — archived ones included.
        let routingSession =
          primary?.session
          ?? list.sessions.first(where: {
            $0.serverId == workspace.serverId
              && environment.workspaces.workspaceId(forSession: $0.id) == workspace.id
          })
        let routingProject =
          primary?.project
          ?? routingSession.flatMap { fallback in
            list.projects.first {
              $0.serverId == workspace.serverId && $0.id == fallback.projectId
            }
          }
        return (
          SidebarWorkspaceListItem(
            workspace: workspace,
            sessions: workspaceSessions,
            primarySession: routingSession,
            project: routingProject
          ),
          primary.flatMap { sessionRank[$0.id] } ?? Int.max,
          workspace.createdAt
        )
      }
      .filter {
        showEmptyWorkspaces || !$0.item.sessions.isEmpty
          // In Nous a workspace whose only open content is a terminal
          // (its last chat closed) is not empty: its tab is a live row.
          || (isNousMode && $0.item.primarySession != nil && $0.item.workspace.hasOpenNonChatContent)
      }
      .sorted {
        if $0.rank != $1.rank { return $0.rank < $1.rank }
        return $0.created > $1.created
      }
      .map(\.item)
  }

  func orderedSessions(in project: Project) -> [ChatSession] {
    let sessions = list.fleetSessions(in: project)
    guard order == .none else {
      return deferredSessionOrder.applying(
        to: automaticallySortedSessions.filter {
          $0.serverId == project.serverId && $0.projectId == project.id
        },
        id: \.sidebarFleetOrderID
      )
    }
    return manuallyOrderedSessions(sessions, session: \.self)
  }

  /// Automatic priority/recency updates keep changing row content while the
  /// pointer is in the sidebar, but their identity order is held until the
  /// pointer leaves. Manual drag order bypasses these snapshots entirely.
  func setAutomaticOrderDeferred(_ isDeferred: Bool) {
    if isDeferred {
      // The hover hold takes over any in-flight settle hold (the lock
      // is first-snapshot-wins, so the frozen order is preserved) and
      // owns it until the pointer leaves.
      cancelReorderSettleHold()
      deferredProjectOrder.lock(to: visibleProjects.map(\.sidebarFleetOrderID))
      deferredSessionOrder.lock(to: chronologicalSessions.map(\.orderingID))
    } else {
      releaseDeferredOrder(animated: true)
    }
  }

  /// Coalesces bursts of automatic reorders. The first change of a burst
  /// commits immediately — it has already rendered by the time this runs —
  /// then the order freezes until the sort has been quiet for
  /// `ReorderSettle.quietDelay`, capped at `ReorderSettle.maxHold` under
  /// sustained churn. While the pointer is inside the sidebar the hover
  /// hold owns the lock instead, and pointer exit releases immediately.
  func scheduleReorderSettleHold() {
    guard order != .none, !isPointerInsideSidebar else { return }
    if !deferredProjectOrder.isLocked, !deferredSessionOrder.isLocked {
      deferredProjectOrder.lock(to: visibleProjects.map(\.sidebarFleetOrderID))
      deferredSessionOrder.lock(to: chronologicalSessions.map(\.orderingID))
      reorderSettleHoldStart = Date()
    }
    let holdStart = reorderSettleHoldStart ?? Date()
    reorderSettleTask?.cancel()
    reorderSettleTask = Task {
      try? await Task.sleep(for: .seconds(ReorderSettle.delay(holdStart: holdStart)))
      guard !Task.isCancelled else { return }
      reorderSettleTask = nil
      reorderSettleHoldStart = nil
      releaseDeferredOrder(animated: true)
    }
  }

  private func cancelReorderSettleHold() {
    reorderSettleTask?.cancel()
    reorderSettleTask = nil
    reorderSettleHoldStart = nil
  }

  func releaseDeferredOrder(animated: Bool) {
    cancelReorderSettleHold()
    guard deferredProjectOrder.isLocked || deferredSessionOrder.isLocked else { return }
    if animated {
      withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
        deferredProjectOrder.unlock()
        deferredSessionOrder.unlock()
      }
    } else {
      deferredProjectOrder.unlock()
      deferredSessionOrder.unlock()
    }
  }
}
