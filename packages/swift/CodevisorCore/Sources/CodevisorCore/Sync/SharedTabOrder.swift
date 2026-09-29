import Foundation

/// Tab order is shared across devices; splits are not.
///
/// Each server pane carries a position key. A device's tab sorts by its
/// smallest pane key (its anchor), so a split tab on one device and the same
/// panes as separate tabs on another still line up. Tabs with no listed
/// pane (the local New Tab page, a pane the server hasn't listed yet) have
/// no key and keep their slot.
public enum SharedTabOrder {
  public struct Move: Equatable, Sendable {
    public let paneId: UUID
    public let position: String
  }

  /// The tabs sorted by their shared keys. Keyless tabs stay where they are.
  public static func sorted(_ tabs: [WorkspaceTab], positions: [UUID: String]) -> [WorkspaceTab] {
    let anchors = tabs.map { anchor(of: $0, positions: positions) }
    let slots = anchors.indices.filter { anchors[$0] != nil }
    let order = slots.sorted { (anchors[$0]!, $0) < (anchors[$1]!, $1) }
    guard order != slots else { return tabs }
    var result = tabs
    for (slot, source) in zip(slots, order) { result[slot] = tabs[source] }
    return result
  }

  /// The tab a dragged row lands in front of when dropped before row
  /// `destination` of a sidebar whose rows name `rowTabIds` (a split lists
  /// one row per pane, so a tab can own several rows). Nil is the end.
  public static func successor(of tabId: UUID, droppedAt destination: Int, rowTabIds: [UUID]) -> UUID? {
    rowTabIds.dropFirst(max(0, destination)).first { $0 != tabId }
  }

  /// The fewest key changes that make `tabs` (the order the user wants) the
  /// order every device sorts to: tabs already in order keep their keys, and
  /// each moved tab gets keys between its kept neighbours.
  public static func moves(for tabs: [WorkspaceTab], positions: [UUID: String]) -> [Move] {
    let keyed: [(panes: [UUID], keys: [String])] = tabs.compactMap { tab in
      let panes = paneIds(of: tab).filter { positions[$0] != nil }
      guard !panes.isEmpty else { return nil }
      return (panes, panes.map { positions[$0]! })
    }
    let anchors = keyed.map { $0.keys.min()! }
    let kept = longestIncreasing(anchors)
    var moves: [Move] = []
    var lower: String?
    for index in keyed.indices {
      let upper = nextKeptAnchor(after: index, kept: kept, anchors: anchors)
      if kept.contains(index) {
        // Prefer the tab's largest key as the bound, so a moved tab lands
        // after every pane of its neighbour even where another device shows
        // that neighbour's panes as separate tabs.
        let largest = keyed[index].keys.max()!
        if let upper, largest >= upper {
          lower = anchors[index]
        } else {
          lower = largest
        }
        continue
      }
      for paneId in keyed[index].panes {
        guard let position = WorkspacePosition.between(lower, upper, id: paneId) else { continue }
        moves.append(Move(paneId: paneId, position: position))
        lower = position
      }
    }
    return moves
  }

  /// The keys of one workspace's server panes (every pane when nil).
  public static func positions(of panes: [ServerWorkspacePane], workspaceId: UUID?) -> [UUID: String] {
    let key = workspaceId?.uuidString.lowercased()
    var result: [UUID: String] = [:]
    for pane in panes where key == nil || pane.workspaceId.lowercased() == key {
      guard let position = pane.position, WorkspacePosition.isValid(position),
        let id = UUID(uuidString: pane.id)
      else { continue }
      result[id] = position
    }
    return result
  }

  static func paneIds(of tab: WorkspaceTab) -> [UUID] {
    tab.root.allGroups.flatMap { $0.state.panes.map(\.id) }
  }

  private static func anchor(of tab: WorkspaceTab, positions: [UUID: String]) -> String? {
    paneIds(of: tab).compactMap { positions[$0] }.min()
  }

  private static func nextKeptAnchor(after index: Int, kept: Set<Int>, anchors: [String]) -> String? {
    guard index + 1 < anchors.count else { return nil }
    return (index + 1..<anchors.count).first(where: kept.contains).map { anchors[$0] }
  }

  /// Indices of one longest strictly increasing subsequence (patience sort).
  static func longestIncreasing(_ values: [String]) -> Set<Int> {
    var tails: [Int] = []
    var previous = [Int?](repeating: nil, count: values.count)
    for index in values.indices {
      var low = 0
      var high = tails.count
      while low < high {
        let mid = (low + high) / 2
        if values[tails[mid]] < values[index] { low = mid + 1 } else { high = mid }
      }
      if low > 0 { previous[index] = tails[low - 1] }
      if low == tails.count { tails.append(index) } else { tails[low] = index }
    }
    var result = Set<Int>()
    var cursor = tails.last
    while let index = cursor {
      result.insert(index)
      cursor = previous[index]
    }
    return result
  }
}
