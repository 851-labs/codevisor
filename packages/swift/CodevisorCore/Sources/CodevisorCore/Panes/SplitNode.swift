import Foundation

public enum SplitOrientation: String, Codable, Sendable {
  case horizontal
  case vertical
}

public enum SplitEdge: String, Codable, Sendable {
  case leading, trailing, top, bottom

  var orientation: SplitOrientation {
    switch self {
    case .leading, .trailing: .horizontal
    case .top, .bottom: .vertical
    }
  }

  var insertsBefore: Bool {
    switch self {
    case .leading, .top: true
    case .trailing, .bottom: false
    }
  }
}

public struct SplitChild: Codable, Sendable, Equatable {
  public var fraction: Double
  public var node: SplitNode

  public init(fraction: Double, node: SplitNode) {
    self.fraction = fraction
    self.node = node
  }
}

public indirect enum SplitNode: Codable, Sendable, Equatable {
  case group(id: UUID, state: PaneGroupState)
  case split(orientation: SplitOrientation, children: [SplitChild])

  public static func leaf(_ state: PaneGroupState, id: UUID = UUID()) -> SplitNode {
    .group(id: id, state: state)
  }

  public var allGroups: [(id: UUID, state: PaneGroupState)] {
    switch self {
    case let .group(id, state):
      [(id, state)]
    case let .split(_, children):
      children.flatMap(\.node.allGroups)
    }
  }

  public func group(id: UUID) -> PaneGroupState? {
    allGroups.first { $0.id == id }?.state
  }

  public func groupId(containingPane paneId: UUID) -> UUID? {
    allGroups.first { $0.state.panes.contains { $0.id == paneId } }?.id
  }

  public func groupId(containingChat sessionId: UUID) -> UUID? {
    allGroups.first { group in
      group.state.panes.contains { $0.kind == .chat && $0.chatSessionId == sessionId }
    }?.id
  }

  public func updatingGroup(id: UUID, _ transform: (PaneGroupState) -> PaneGroupState) -> SplitNode {
    switch self {
    case let .group(groupId, state):
      groupId == id ? .group(id: groupId, state: transform(state)) : self
    case let .split(orientation, children):
      .split(
        orientation: orientation,
        children: children.map {
          SplitChild(fraction: $0.fraction, node: $0.node.updatingGroup(id: id, transform))
        })
    }
  }

  public func splitting(
    groupId targetId: UUID,
    edge: SplitEdge,
    newGroupId: UUID,
    newGroupState: PaneGroupState
  ) -> SplitNode {
    SplitTreeInsertion.split(
      self, targetId: targetId, edge: edge, newGroupId: newGroupId, newGroupState: newGroupState
    )
  }

  public func removingGroup(id: UUID) -> SplitNode? {
    switch self {
    case let .group(groupId, _):
      return groupId == id ? nil : self
    case let .split(orientation, children):
      let remaining = children.compactMap { child -> SplitChild? in
        guard let node = child.node.removingGroup(id: id) else { return nil }
        return SplitChild(fraction: child.fraction, node: node)
      }
      guard !remaining.isEmpty else { return nil }
      if remaining.count == 1 { return remaining[0].node }
      return SplitNode.split(orientation: orientation, children: remaining).normalized
    }
  }

  public func movingGroup(id sourceId: UUID, relativeTo targetId: UUID, edge: SplitEdge) -> SplitNode {
    guard sourceId != targetId,
      let sourceState = group(id: sourceId),
      group(id: targetId) != nil,
      let withoutSource = removingGroup(id: sourceId)
    else { return self }

    return withoutSource.splitting(
      groupId: targetId,
      edge: edge,
      newGroupId: sourceId,
      newGroupState: sourceState
    )
  }

  public func replacingSplitFractions(
    at branchPath: [Int],
    with fractions: [Double]
  ) -> SplitNode {
    guard case let .split(orientation, children) = self else { return self }
    if branchPath.isEmpty {
      guard children.count == fractions.count else { return self }
      return .split(
        orientation: orientation,
        children: zip(children, fractions).map {
          SplitChild(fraction: $1, node: $0.node)
        }
      )
    }

    let childIndex = branchPath[0]
    guard children.indices.contains(childIndex) else { return self }
    var updated = children
    updated[childIndex].node = updated[childIndex].node.replacingSplitFractions(
      at: Array(branchPath.dropFirst()),
      with: fractions
    )
    return .split(orientation: orientation, children: updated)
  }

  public var prunedEmptyGroups: SplitNode? {
    switch self {
    case let .group(_, state):
      return state.panes.isEmpty ? nil : self
    case let .split(orientation, children):
      let remaining = children.compactMap { child -> SplitChild? in
        guard let node = child.node.prunedEmptyGroups else { return nil }
        return SplitChild(fraction: child.fraction, node: node)
      }
      guard !remaining.isEmpty else { return nil }
      if remaining.count == 1 { return remaining[0].node }
      return SplitNode.split(orientation: orientation, children: remaining).normalized
    }
  }

  public static func flooredFractions(
    _ fractions: [Double],
    minFraction: Double
  ) -> [Double] {
    let count = fractions.count
    guard count > 0, minFraction > 0 else { return fractions }
    let equal = [Double](repeating: 1 / Double(count), count: count)
    guard minFraction * Double(count) < 1 else { return equal }
    var clamped = Set<Int>()
    while clamped.count < count {
      let flexible = fractions.indices.filter { !clamped.contains($0) }
      let flexibleTotal = flexible.map { fractions[$0] }.reduce(0, +)
      let available = 1 - Double(clamped.count) * minFraction
      func share(_ index: Int) -> Double {
        flexibleTotal > 0
          ? fractions[index] / flexibleTotal * available
          : available / Double(flexible.count)
      }
      let starved = flexible.filter { share($0) < minFraction }
      if starved.isEmpty {
        var result = [Double](repeating: minFraction, count: count)
        for index in flexible {
          result[index] = share(index)
        }
        return result
      }
      clamped.formUnion(starved)
    }
    return equal
  }

  public var normalized: SplitNode {
    switch self {
    case .group:
      return self
    case let .split(orientation, children):
      let total = children.map(\.fraction).reduce(0, +)
      let scale = total > 0 ? 1 / total : 0
      return .split(
        orientation: orientation,
        children: children.map {
          SplitChild(
            fraction: total > 0 ? $0.fraction * scale : 1 / Double(children.count),
            node: $0.node.normalized
          )
        })
    }
  }
}
