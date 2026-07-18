//  The workspace's center-area layout: a tree of splits whose leaves are
//  tabbed pane groups (the VS Code / zed grid model — zed's
//  `pane_group.rs` Member::Axis/Pane is the closest reference). Pure value
//  types: every operation returns a new tree, so layout rules are
//  unit-testable and persistence is plain Codable.

import Foundation

public enum SplitOrientation: String, Codable, Sendable {
    /// Children side by side (a vertical divider between them).
    case horizontal
    /// Children stacked (a horizontal divider between them).
    case vertical
}

/// Which edge of a group a pane is dropped on, creating a split.
public enum SplitEdge: String, Codable, Sendable {
    case leading, trailing, top, bottom

    var orientation: SplitOrientation {
        switch self {
        case .leading, .trailing: .horizontal
        case .top, .bottom: .vertical
        }
    }

    /// Whether the new group lands before (leading/top) or after the target.
    var insertsBefore: Bool {
        switch self {
        case .leading, .top: true
        case .trailing, .bottom: false
        }
    }
}

/// One child of a split: a subtree plus its share of the split's length.
/// Fractions of a split's children always sum to ~1.
public struct SplitChild: Codable, Sendable, Equatable {
    public var fraction: Double
    public var node: SplitNode

    public init(fraction: Double, node: SplitNode) {
        self.fraction = fraction
        self.node = node
    }
}

/// A node in the center-area layout tree: a leaf pane group (tabs) or a
/// split of subtrees. Group ids are stable (persisted) — they identify drop
/// targets, focus, and per-group model caches across restarts.
public indirect enum SplitNode: Codable, Sendable, Equatable {
    case group(id: UUID, state: PaneGroupState)
    case split(orientation: SplitOrientation, children: [SplitChild])
}

extension SplitNode {
    /// A tree containing a single group leaf.
    public static func leaf(_ state: PaneGroupState, id: UUID = UUID()) -> SplitNode {
        .group(id: id, state: state)
    }

    /// Every group in the tree, leftmost-first (reading order).
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

    /// The group containing the pane, if any.
    public func groupId(containingPane paneId: UUID) -> UUID? {
        allGroups.first { $0.state.panes.contains { $0.id == paneId } }?.id
    }

    /// The group containing the chat pane for `sessionId`, if any.
    public func groupId(containingChat sessionId: UUID) -> UUID? {
        allGroups.first { group in
            group.state.panes.contains { $0.kind == .chat && $0.chatSessionId == sessionId }
        }?.id
    }

    /// Returns the tree with the group's state replaced by `transform`'s
    /// result. No-op when the group doesn't exist.
    public func updatingGroup(id: UUID, _ transform: (PaneGroupState) -> PaneGroupState) -> SplitNode {
        switch self {
        case let .group(groupId, state):
            groupId == id ? .group(id: groupId, state: transform(state)) : self
        case let .split(orientation, children):
            .split(orientation: orientation, children: children.map {
                SplitChild(fraction: $0.fraction, node: $0.node.updatingGroup(id: id, transform))
            })
        }
    }

    /// Splits the target group on `edge`, inserting `newGroup` beside it. The
    /// new group takes half the target's share. When the target's parent
    /// split already has the edge's orientation the new group becomes a
    /// sibling (VS Code behavior); otherwise the leaf is wrapped in a new
    /// split. Returns the tree unchanged if the target doesn't exist.
    public func splitting(
        groupId targetId: UUID,
        edge: SplitEdge,
        newGroupId: UUID,
        newGroupState: PaneGroupState
    ) -> SplitNode {
        splittingNode(targetId: targetId, edge: edge, newGroupId: newGroupId, newGroupState: newGroupState)
    }

    private func splittingNode(
        targetId: UUID, edge: SplitEdge, newGroupId: UUID, newGroupState: PaneGroupState
    ) -> SplitNode {
        switch self {
        case let .group(id, state):
            guard id == targetId else { return self }
            let target = SplitChild(fraction: 0.5, node: .group(id: id, state: state))
            let added = SplitChild(fraction: 0.5, node: .group(id: newGroupId, state: newGroupState))
            let children = edge.insertsBefore ? [added, target] : [target, added]
            return .split(orientation: edge.orientation, children: children)
        case let .split(orientation, children):
            // Same-orientation parent: insert as a sibling, halving the
            // target child's share, instead of nesting another split.
            if orientation == edge.orientation,
               let index = children.firstIndex(where: {
                   if case let .group(id, _) = $0.node { return id == targetId }
                   return false
               }) {
                var updated = children
                let share = updated[index].fraction / 2
                updated[index].fraction = share
                let added = SplitChild(fraction: share, node: .group(id: newGroupId, state: newGroupState))
                updated.insert(added, at: edge.insertsBefore ? index : index + 1)
                return .split(orientation: orientation, children: updated)
            }
            return .split(orientation: orientation, children: children.map {
                SplitChild(
                    fraction: $0.fraction,
                    node: $0.node.splittingNode(
                        targetId: targetId, edge: edge,
                        newGroupId: newGroupId, newGroupState: newGroupState
                    )
                )
            })
        }
    }

    /// Removes a group from the tree: its siblings absorb its share, a split
    /// left with one child collapses into that child (VS Code's dissolve
    /// rule), and removing the last group yields nil.
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

    /// The tree with every EMPTY group removed (siblings absorb shares,
    /// single-child splits collapse); nil when no group holds a pane.
    /// Load-time healing: a group is only ever legitimately empty for the
    /// instant between a split's creation and the dropped pane's adoption,
    /// so one persisted across launches is a stale artifact (e.g. a crash
    /// mid-drop) that would render as a dead strip forever.
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

    /// Render-time fraction floors: fractions adjusted so every child gets
    /// at least `minFraction` of the axis, shrinking the others
    /// proportionally (divider drags already clamp — this guards WINDOW
    /// resizes, which rescale every child at once). When the floor is
    /// infeasible (n·min > 1) children share equally.
    public static func flooredFractions(
        _ fractions: [Double],
        minFraction: Double
    ) -> [Double] {
        let count = fractions.count
        guard count > 0, minFraction > 0 else { return fractions }
        let equal = [Double](repeating: 1 / Double(count), count: count)
        guard minFraction * Double(count) < 1 else { return equal }
        // Waterfall: clamp the starved children to the floor, redistribute
        // what's left across the rest proportionally; clamping can starve
        // further children, so repeat until stable.
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

    /// Rescales every split's child fractions to sum to 1.
    public var normalized: SplitNode {
        switch self {
        case .group:
            return self
        case let .split(orientation, children):
            let total = children.map(\.fraction).reduce(0, +)
            let scale = total > 0 ? 1 / total : 0
            return .split(orientation: orientation, children: children.map {
                SplitChild(
                    fraction: total > 0 ? $0.fraction * scale : 1 / Double(children.count),
                    node: $0.node.normalized
                )
            })
        }
    }
}
