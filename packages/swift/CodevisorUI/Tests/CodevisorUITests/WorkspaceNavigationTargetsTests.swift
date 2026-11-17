import Foundation
import Observation
import Testing
@testable import CodevisorUI

@MainActor
struct WorkspaceNavigationTargetsTests {
  @Test("Moving the selection notifies only the workspaces that lose or gain it")
  func selectionNotifiesOnlyAffectedWorkspaces() {
    let targets = WorkspaceNavigationTargets()
    let (first, second, bystander) = (UUID(), UUID(), UUID())
    targets.select(first)
    let notified = NotifiedWorkspaces()
    for id in [first, second, bystander] {
      withObservationTracking {
        _ = targets.isSelected(id)
      } onChange: {
        notified.ids.append(id)
      }
    }

    targets.select(second)

    #expect(Set(notified.ids) == [first, second])
    #expect(!targets.isSelected(first))
    #expect(targets.isSelected(second))
    #expect(!targets.isSelected(bystander))
  }

  @Test("Clearing the selection leaves no workspace selected")
  func clearingSelection() {
    let targets = WorkspaceNavigationTargets()
    let workspace = UUID()
    targets.select(workspace)

    targets.select(nil)

    #expect(!targets.isSelected(workspace))
  }
}

private final class NotifiedWorkspaces: @unchecked Sendable {
  var ids: [UUID] = []
}
