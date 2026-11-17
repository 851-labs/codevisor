import Foundation
import Testing
@testable import CodevisorUI

struct SidebarSelectionSyncTests {
  private let workspace = UUID()
  private let tab = UUID()
  private let other = UUID()

  private func target(archived: Bool = false) -> SidebarSelectionTarget {
    SidebarSelectionTarget(workspaceID: workspace, tabID: tab, isArchived: archived)
  }

  @Test("A selected workspace that is listed anyway does not shape the rows")
  func listedSelectionNeedsNoReveal() {
    let revealed = SidebarSelectionSync.revealed(showing: target(), unrevealedRowIDs: [.workspace(workspace)])

    #expect(revealed == nil)
  }

  @Test("A selected workspace hidden by a collapsed group is revealed with its selected tab")
  func hiddenSelectionIsRevealed() {
    let revealed = SidebarSelectionSync.revealed(showing: target(), unrevealedRowIDs: [.workspace(other)])

    #expect(revealed == SidebarRevealedSelection(workspaceID: workspace, tabID: tab))
  }

  @Test("A selected archived workspace always shapes the rows, whichever tab it shows")
  func archivedSelectionIsAlwaysRevealed() {
    let revealed = SidebarSelectionSync.revealed(
      showing: target(archived: true), unrevealedRowIDs: [.workspace(workspace)])

    #expect(revealed == SidebarRevealedSelection(workspaceID: workspace, tabID: nil))
  }

  @Test("The selected row is the tab when it is listed, otherwise the workspace")
  func selectedRowPrefersTheListedTab() {
    #expect(SidebarSelectionSync.selectedRow(showing: target(), rowIDs: [.tab(tab)]) == .tab(tab))
    #expect(SidebarSelectionSync.selectedRow(showing: target(), rowIDs: []) == .workspace(workspace))
    #expect(SidebarSelectionSync.selectedRow(showing: nil, rowIDs: [.tab(tab)]) == nil)
  }
}
