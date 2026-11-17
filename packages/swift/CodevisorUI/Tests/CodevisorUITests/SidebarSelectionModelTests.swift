import Foundation
import Observation
import Testing
@testable import CodevisorUI

@MainActor
struct SidebarSelectionModelTests {
  private let listed = UUID()
  private let hidden = UUID()
  private let tab = UUID()

  private func target(_ workspace: UUID) -> SidebarSelectionTarget {
    SidebarSelectionTarget(workspaceID: workspace, tabID: tab, isArchived: false)
  }

  private func rowsRequested(by change: () -> Void, in model: SidebarSelectionModel) -> Bool {
    let requested = Requested()
    withObservationTracking {
      _ = model.reveal(amongUnrevealed: [.workspace(listed)])
    } onChange: {
      requested.value = true
    }
    change()
    return requested.value
  }

  @Test("Selecting a workspace that is listed anyway asks for no new rows and moves only the highlight")
  func listedSelectionKeepsTheRows() {
    let model = SidebarSelectionModel()

    let requested = rowsRequested(by: { model.select(target(listed)) }, in: model)
    model.highlight(among: [.workspace(listed)])

    #expect(!requested)
    #expect(model.rows.isSelected(.workspace(listed)))
  }

  @Test("Selecting a hidden workspace asks for new rows, which then reveal it")
  func hiddenSelectionAsksForRows() {
    let model = SidebarSelectionModel()

    let requested = rowsRequested(by: { model.select(target(hidden)) }, in: model)

    #expect(requested)
    #expect(
      model.reveal(amongUnrevealed: [.workspace(listed)])
        == SidebarRevealedSelection(workspaceID: hidden, tabID: tab))
  }

  @Test("Collapsing the group around the selected workspace reveals it in the same derivation")
  func collapseRevealsAtOnce() {
    let model = SidebarSelectionModel()
    _ = model.reveal(amongUnrevealed: [.workspace(listed)])
    model.select(target(listed))

    let revealed = model.reveal(amongUnrevealed: [])

    #expect(revealed == SidebarRevealedSelection(workspaceID: listed, tabID: tab))
  }

  @Test("Moving from a revealed workspace to a listed one asks for rows without the reveal")
  func leavingARevealedWorkspaceDropsTheReveal() {
    let model = SidebarSelectionModel()
    model.select(target(hidden))

    let requested = rowsRequested(by: { model.select(target(listed)) }, in: model)

    #expect(requested)
    #expect(model.reveal(amongUnrevealed: [.workspace(listed)]) == nil)
  }
}

private final class Requested: @unchecked Sendable {
  var value = false
}
