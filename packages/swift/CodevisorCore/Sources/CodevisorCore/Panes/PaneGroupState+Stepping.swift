import Foundation

extension PaneGroupState {
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
