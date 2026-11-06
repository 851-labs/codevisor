import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("Floating panes")
struct FloatingPanesTests {
  private let workspaceId = UUID()

  @Test("Floated panes are remembered per workspace across instances")
  func floatedPanesPersist() {
    let preferences = ClientPreferences()
    let leafId = UUID()
    FloatingPanes(preferences: preferences).float(FloatingPaneKey(workspaceId: workspaceId, leafId: leafId))

    let reloaded = FloatingPanes(preferences: preferences)

    #expect(reloaded.leafIds(in: workspaceId) == [leafId])
    #expect(reloaded.leafIds(in: UUID()).isEmpty)
    #expect(reloaded.workspaceIds == [workspaceId])
  }

  @Test("Docking a pane forgets only that pane")
  func dockingForgetsOnePane() {
    let panes = FloatingPanes(preferences: ClientPreferences())
    let kept = FloatingPaneKey(workspaceId: workspaceId, leafId: UUID())
    let docked = FloatingPaneKey(workspaceId: workspaceId, leafId: UUID())
    panes.float(kept)
    panes.float(docked)

    panes.dock(docked)

    #expect(panes.leafIds(in: workspaceId) == [kept.leafId])
  }
}
