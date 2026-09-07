import Foundation

/// Persisted workspace ranks, including archived or temporarily offline rows.
public struct WorkspaceSidebarOrder {
  public let ids: [UUID]

  public init(_ ids: [UUID]) {
    var seen: Set<UUID> = []
    self.ids = ids.filter { seen.insert($0).inserted }
  }

  /// New workspaces enter at the top in the caller's initial order.
  public func including(_ visibleIDs: [UUID]) -> WorkspaceSidebarOrder {
    let saved = Set(ids)
    return WorkspaceSidebarOrder(visibleIDs.filter { !saved.contains($0) } + ids)
  }

  public func applying(to visibleIDs: [UUID]) -> [UUID] {
    let visible = Set(visibleIDs)
    return including(visibleIDs).ids.filter { visible.contains($0) }
  }

  /// Move within the visible list while preserving hidden rows' saved slots.
  public func moving(_ source: UUID, to destination: UUID, visibleIDs: [UUID]) -> WorkspaceSidebarOrder {
    var reordered = applying(to: visibleIDs)
    guard source != destination,
      let sourceIndex = reordered.firstIndex(of: source),
      let destinationIndex = reordered.firstIndex(of: destination)
    else { return self }
    let moved = reordered.remove(at: sourceIndex)
    reordered.insert(moved, at: destinationIndex)
    let visible = Set(reordered)
    var remaining = reordered.makeIterator()
    return WorkspaceSidebarOrder(
      including(visibleIDs).ids.map { visible.contains($0) ? remaining.next() ?? $0 : $0 }
    )
  }
}
