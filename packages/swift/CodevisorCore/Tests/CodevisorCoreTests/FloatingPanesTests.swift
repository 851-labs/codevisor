import CoreGraphics
import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("Floating panes")
struct FloatingPanesTests {
  private let workspaceId = UUID()

  private func key() -> FloatingPaneKey {
    FloatingPaneKey(workspaceId: workspaceId, leafId: UUID())
  }

  @Test("Floated panes and their frames are remembered per workspace across instances")
  func floatedPanesPersist() {
    let preferences = ClientPreferences()
    let floated = key()
    let frame = CGRect(x: 40, y: 60, width: 420, height: 480)
    FloatingPanes(preferences: preferences).float(floated)
    FloatingPanes(preferences: preferences).move(floated, to: frame)

    let reloaded = FloatingPanes(preferences: preferences)

    #expect(reloaded.panes(in: workspaceId).map(\.frame) == [frame])
    #expect(reloaded.leafIds(in: UUID()).isEmpty)
  }

  @Test("Docking a pane forgets only that pane")
  func dockingForgetsOnePane() {
    let panes = FloatingPanes(preferences: ClientPreferences())
    let kept = key()
    let docked = key()
    panes.float(kept)
    panes.float(docked)

    panes.dock(docked)

    #expect(panes.leafIds(in: workspaceId) == [kept.leafId])
  }

  @Test("Bringing a pane to the front stacks it last")
  func bringToFrontStacksLast() {
    let panes = FloatingPanes(preferences: ClientPreferences())
    let back = key()
    let front = key()
    panes.float(back)
    panes.float(front)

    panes.bringToFront(back)

    #expect(panes.panes(in: workspaceId).map(\.leafId) == [front.leafId, back.leafId])
  }
}
