import CodevisorCore
import Foundation

/// Keeps unrelated SwiftUI updates (notably composer keystrokes) from sorting
/// the complete Home collection again. The cache stores only identity order;
/// callers always remap those ids onto the newest session value structs.
@MainActor
final class HomeSessionOrderingCache {
    private struct Input: Equatable {
        let id: UUID
        let priority: Int
        let timestamp: Date
        let manualRank: Int
        let sourceIndex: Int
    }

    private var order: HomeOrder?
    private var inputs: [Input] = []
    private var orderedIDs: [UUID] = []

    func sessions(
        _ values: [ChatSession],
        order newOrder: HomeOrder,
        manualRanks: [UUID: Int],
        priority: (ChatSession) -> Int
    ) -> [ChatSession] {
        let newInputs = values.enumerated().map { index, session in
            let timestamp: Date =
                switch newOrder {
                case .created: session.createdAt
                case .updated, .none: session.sidebarStateChangedAt
                }
            return Input(
                id: session.id,
                priority: newOrder == .updated ? priority(session) : 0,
                timestamp: timestamp,
                manualRank: manualRanks[session.id] ?? Int.max,
                sourceIndex: index
            )
        }
        if newOrder != order || newInputs != inputs {
            order = newOrder
            inputs = newInputs
            orderedIDs = newInputs.sorted { left, right in
                if newOrder == .updated, left.priority != right.priority {
                    return left.priority < right.priority
                }
                if newOrder == .none, left.manualRank != right.manualRank {
                    return left.manualRank < right.manualRank
                }
                if left.timestamp != right.timestamp { return left.timestamp > right.timestamp }
                return left.sourceIndex < right.sourceIndex
            }.map(\.id)
        }
        let byID = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return orderedIDs.compactMap { byID[$0] }
    }
}
