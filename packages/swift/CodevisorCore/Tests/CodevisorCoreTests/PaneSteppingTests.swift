import Foundation
import Testing

@testable import CodevisorCore

@Suite("Pane stepping")
struct PaneSteppingTests {
  private func group(count: Int) -> PaneGroupState {
    var state = PaneGroupState()
    for _ in 0..<count { _ = state.addNewTabPane() }
    return state
  }

  @Test("Next and previous tab move one place in tab order")
  func stepsOnePlace() {
    let state = group(count: 3)
    let ids = state.panes.map(\.id)
    #expect(state.pane(steppingFrom: ids[1], by: 1)?.id == ids[2])
    #expect(state.pane(steppingFrom: ids[1], by: -1)?.id == ids[0])
  }

  @Test("Stepping wraps past either end")
  func wraps() {
    let state = group(count: 3)
    let ids = state.panes.map(\.id)
    #expect(state.pane(steppingFrom: ids[2], by: 1)?.id == ids[0])
    #expect(state.pane(steppingFrom: ids[0], by: -1)?.id == ids[2])
    #expect(state.pane(steppingFrom: ids[0], by: -4)?.id == ids[2])
  }

  @Test("A lone tab or an unknown tab has nowhere to step")
  func nowhereToStep() {
    let single = group(count: 1)
    #expect(single.pane(steppingFrom: single.panes[0].id, by: 1) == nil)
    #expect(group(count: 3).pane(steppingFrom: UUID(), by: 1) == nil)
  }
}
