import Foundation

/// Keyboard stepping through tabs (Previous/Next Tab): move `offset` places
/// in order, wrapping at either end.
extension PaneGroupState {
  /// The pane `offset` places from `paneId` in tab order. Nil when there is
  /// nowhere else to go or `paneId` isn't in this group.
  public func pane(steppingFrom paneId: UUID, by offset: Int) -> PaneDescriptorState? {
    guard let index = panes.firstIndex(where: { $0.id == paneId }),
      let target = Self.wrappedIndex(index, by: offset, count: panes.count)
    else { return nil }
    return panes[target]
  }

  private static func wrappedIndex(_ index: Int, by offset: Int, count: Int) -> Int? {
    guard count > 1 else { return nil }
    return ((index + offset) % count + count) % count
  }
}
