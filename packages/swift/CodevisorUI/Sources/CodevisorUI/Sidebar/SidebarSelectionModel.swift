import Foundation
import Observation

@MainActor
@Observable
public final class SidebarSelectionModel {
  public let rows = SelectionMarkers<SidebarRowID>()

  private var revealRevision = 0
  @ObservationIgnored private var target: SidebarSelectionTarget?
  @ObservationIgnored private var unrevealedRowIDs: Set<SidebarRowID> = []
  @ObservationIgnored public private(set) var currentReveal: SidebarRevealedSelection?

  public init() {}

  public func reveal(amongUnrevealed rowIDs: Set<SidebarRowID>) -> SidebarRevealedSelection? {
    _ = revealRevision
    unrevealedRowIDs = rowIDs
    currentReveal = SidebarSelectionSync.revealed(showing: target, unrevealedRowIDs: rowIDs)
    return currentReveal
  }

  public func select(_ target: SidebarSelectionTarget?) {
    self.target = target
    let needed = SidebarSelectionSync.revealed(showing: target, unrevealedRowIDs: unrevealedRowIDs)
    if needed != currentReveal { revealRevision &+= 1 }
  }

  public func highlight(among rowIDs: Set<SidebarRowID>) {
    rows.select(SidebarSelectionSync.selectedRow(showing: target, rowIDs: rowIDs))
  }
}
