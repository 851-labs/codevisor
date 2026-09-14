import Foundation

public struct AgentTerminalChanges: Sendable {
  public var updated: [PaneDescriptorState] = []
  public var removed: [PaneDescriptorState] = []
  public var isEmpty: Bool { updated.isEmpty && removed.isEmpty }
}

extension Workspace {
  /// Reconciles one chat's task snapshot into ordinary workspace tabs without
  /// stealing selection. No pruning occurs before that chat's first snapshot.
  /// Legacy terminals with no owner are adopted only when a live task matches.
  public mutating func syncAgentTerminals(
    _ tasks: [(terminalKey: String, name: String)],
    owner: UUID,
    pruneEnded: Bool
  ) -> AgentTerminalChanges {
    var changes = AgentTerminalChanges()
    for task in tasks {
      if var existing = allPanes.first(where: {
        $0.kind == .terminal && $0.terminalKey == task.terminalKey
      }) {
        if existing.isAgentTerminal, existing.ownerChatSessionId == nil {
          existing.ownerChatSessionId = owner
          upsertCenterPane(existing, selecting: false)
          changes.updated.append(existing)
        }
        continue
      }
      let pane = PaneDescriptorState(
        id: UUID(), kind: .terminal, name: task.name, terminalKey: task.terminalKey,
        attachOnly: true, ownerChatSessionId: owner
      )
      upsertCenterPane(pane, selecting: false)
      changes.updated.append(pane)
    }
    guard pruneEnded else { return changes }
    let liveKeys = Set(tasks.map(\.terminalKey))
    changes.removed = allPanes.filter {
      $0.isAgentTerminal && $0.ownerChatSessionId == owner && !liveKeys.contains($0.terminalKey)
    }
    let removedIDs = Set(changes.removed.map(\.id))
    for tab in centerTabs {
      guard
        tab.root.allGroups.contains(where: {
          $0.state.panes.contains { removedIDs.contains($0.id) }
        }), let index = centerTabs.firstIndex(where: { $0.id == tab.id })
      else { continue }
      for group in tab.root.allGroups {
        centerTabs[index].root = centerTabs[index].root.updatingGroup(id: group.id) { state in
          var state = state
          for pane in state.panes where removedIDs.contains(pane.id) {
            state.removePane(id: pane.id)
          }
          return state
        }
      }
      pruneClosedCenterTab(tab.id)
    }
    return changes
  }
}
