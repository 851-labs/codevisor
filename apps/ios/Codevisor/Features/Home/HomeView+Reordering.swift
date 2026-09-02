import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

/// Manual group and agent reordering for the home list.
extension HomeView {
  /// Group rows always use the same native List move interaction as agents.
  /// Persisting only these direct ForEach IDs keeps expanded disclosure
  /// children out of the destination model: a drop below an expanded group
  /// moves below that group rather than into its agent rows.
  func moveWorkspaces(from source: IndexSet, to destination: Int) {
    var ids = workspaceItems.map(\.id)
    ids.move(fromOffsets: source, toOffset: destination)
    manualWorkspaceOrder = mergedPreferenceOrder(
      visibleIDs: ids,
      existingRawValue: manualWorkspaceOrder
    )
  }

  func moveProjects(from source: IndexSet, to destination: Int) {
    var ids = projectItems.map(\.id)
    ids.move(fromOffsets: source, toOffset: destination)
    manualProjectOrder = mergedPreferenceOrder(
      visibleIDs: ids,
      existingRawValue: manualProjectOrder
    )
  }

  func groupReorderBinding(for organization: HomeOrganization) -> Binding<Bool> {
    Binding(
      get: { groupReorderOrganization == organization },
      set: { isReordering in
        if isReordering {
          beginGroupReorder(for: organization)
        } else {
          finishGroupReorder()
        }
      }
    )
  }

  private func beginGroupReorder(for organization: HomeOrganization) {
    guard organization == self.organization,
      organization != .compact
    else { return }
    switch organization {
    case .byWorkspace:
      groupReorderInitialOrder = manualWorkspaceOrder
    case .byProject:
      groupReorderInitialOrder = manualProjectOrder
    case .compact:
      return
    }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      groupReorderOrganization = organization
    }
  }

  func cancelGroupReorder() {
    guard let organization = groupReorderOrganization,
      let initialOrder = groupReorderInitialOrder
    else {
      finishGroupReorder()
      return
    }
    withAnimation(.snappy(duration: 0.24)) {
      switch organization {
      case .byWorkspace:
        manualWorkspaceOrder = initialOrder
      case .byProject:
        manualProjectOrder = initialOrder
      case .compact:
        break
      }
      groupReorderOrganization = nil
    }
    groupReorderInitialOrder = nil
  }

  func finishGroupReorder() {
    withAnimation(.snappy(duration: 0.24)) {
      groupReorderOrganization = nil
    }
    groupReorderInitialOrder = nil
  }

  func clearGroupReorderPresentation() {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      groupReorderOrganization = nil
    }
    groupReorderInitialOrder = nil
  }

  func agentMoveAction(
    for sessions: [ChatSession]
  ) -> ((IndexSet, Int) -> Void)? {
    guard order == .none, groupReorderOrganization == nil else { return nil }
    return { source, destination in
      moveSessions(sessions, from: source, to: destination)
    }
  }

  /// Reorders only the agents visible in a particular group, then projects
  /// that relative order back into the global manual agent sequence. This
  /// keeps agents in other projects/workspaces exactly where they were.
  private func moveSessions(
    _ sessions: [ChatSession],
    from source: IndexSet,
    to destination: Int
  ) {
    guard order == .none else { return }
    var movedIDs = sessions.map(\.id)
    movedIDs.move(fromOffsets: source, toOffset: destination)

    let movedIDSet = Set(movedIDs)
    var visibleIDs = visibleSessions.map(\.id)
    var replacements = movedIDs.makeIterator()
    for index in visibleIDs.indices where movedIDSet.contains(visibleIDs[index]) {
      guard let replacement = replacements.next() else { break }
      visibleIDs[index] = replacement
    }
    manualSessionOrder = mergedPreferenceOrder(
      visibleIDs: visibleIDs,
      existingRawValue: manualSessionOrder
    )
  }
}
