import Foundation

public enum SharedTabOrder {
  public struct Move: Equatable, Sendable {
    public let paneId: UUID
    public let position: String
  }

  public static func sorted(_ tabs: [WorkspaceTab], positions: [UUID: String]) -> [WorkspaceTab] {
    let anchors = tabs.map { anchor(of: $0, positions: positions) }
    let slots = anchors.indices.filter { anchors[$0] != nil }
    let order = slots.sorted { (anchors[$0]!, $0) < (anchors[$1]!, $1) }
    guard order != slots else { return tabs }
    var result = tabs
    for (slot, source) in zip(slots, order) { result[slot] = tabs[source] }
    return result
  }

  public static func successor(of tabId: UUID, droppedAt destination: Int, rowTabIds: [UUID]) -> UUID? {
    rowTabIds.dropFirst(max(0, destination)).first { $0 != tabId }
  }

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
